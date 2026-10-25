///|
async test "execution profile precedence is shared by queries and prepared statements but never implies idempotence" {
  @async.with_timeout(6000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let defaults = @client.ExecutionProfile::new(
        consistency=Quorum,
        page_size=2,
        retry=@client.RetryPolicy::new(max_attempts=2, delay_ms=0),
      )
      let other = @client.ExecutionProfile::new(consistency=All, page_size=3)
      let explicit = @protocol.QueryOptions::new(consistency=One, page_size=5)
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        for
          (cql, options) in [
            ("default", defaults.options()),
            ("profile", other.options()),
            ("options", explicit),
          ] {
          let actual = receive(peer)
          assert_eq(actual.body, @protocol.query(cql, options~).body)
          respond(peer, actual.header.stream, 8, b"\x00\x00\x00\x01")
        }
        let prepare = receive(peer)
        assert_eq(prepare.header.opcode, 9)
        respond(peer, prepare.header.stream, 8, prepared_result(b"statement"))
        for options in [other.options(), defaults.options(), explicit] {
          let actual = receive(peer)
          assert_eq(
            actual.body,
            @protocol.execute(
              b"statement",
              b"metadata",
              [Integer(42)],
              options~,
            ).body,
          )
          respond(peer, actual.header.stream, 8, rows_result([42], None))
        }
        for
          (cql, failure) in [
            ("once", true),
            ("retry", true),
            ("retry", false),
            ("override_retry", true),
            ("after", false),
          ] {
          let actual = receive(peer)
          assert_eq(@codec.Reader::new(actual.body).long_string(), cql)
          respond(
            peer,
            actual.header.stream,
            if failure {
              0
            } else {
              8
            },
            if failure {
              overload_error()
            } else {
              b"\x00\x00\x00\x01"
            },
          )
        }
        assert_eq(peer.read_some(), None)
      })
      @client.with_session_builder(
        config=@client.SessionBuilder::new(
          connection=@client.ConnectionBuilder::new(port=server.addr.port()),
          execution_profile=defaults,
        ),
        session => {
          assert_true(session.query("default") is Void)
          assert_true(
            session.query_with_profile("profile", profile=other) is Void,
          )
          assert_true(
            session.query_with_profile(
              "options",
              profile=other,
              options=explicit,
            )
            is Void,
          )
          let statement = session.prepare_with_profile(
            "SELECT id FROM t WHERE id=?",
            profile=other,
          )
          assert_true(statement.execute([Integer(42)]) is Rows(_))
          assert_true(
            statement.execute_with_profile([Integer(42)], profile=defaults)
            is Rows(_),
          )
          assert_true(
            statement.execute([Integer(42)], options=explicit) is Rows(_),
          )
          assert_true(
            try {
              ignore(session.query("once"))
              false
            } catch {
              @client.Server(_) => true
              _ => false
            },
          )
          assert_eq(
            session.query_with_info("retry", idempotent=true).info.attempt_count,
            2,
          )
          assert_true(
            try {
              ignore(
                session.query(
                  "override_retry",
                  idempotent=true,
                  retry=@client.RetryPolicy::new(max_attempts=1),
                ),
              )
              false
            } catch {
              @client.Server(_) => true
              _ => false
            },
          )
          assert_true(session.query("after") is Void)
          assert_eq(session.resources().active, 0)
        },
      )
      worker.wait()
    })
  })
}

///|
async test "profile operation timeout and explicit deadline have distinct precedence and late replies remain isolated" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let slow = receive(peer)
        assert_eq(@codec.Reader::new(slow.body).long_string(), "slow")
        release.get()
        respond(peer, slow.header.stream, 8, b"\x00\x00\x00\x01")
        let longer = receive(peer)
        assert_eq(@codec.Reader::new(longer.body).long_string(), "override")
        @async.sleep(30)
        respond(peer, longer.header.stream, 8, b"\x00\x00\x00\x01")
        let prepare = receive(peer)
        assert_eq(prepare.header.opcode, 9)
        release.get()
        respond(peer, prepare.header.stream, 8, prepared_result(b"late"))
        assert_eq(peer.read_some(), None)
      })
      @client.with_session_builder(
        config=@client.SessionBuilder::new(
          connection=@client.ConnectionBuilder::new(
            port=server.addr.port(),
            operation_timeout_ms=10000,
          ),
          execution_profile=@client.ExecutionProfile::new(timeout_ms=500),
        ),
        session => {
          wait_session_nodes(session, 1)
          assert_true(
            try {
              ignore(session.query("slow"))
              false
            } catch {
              @client.TimedOut(info) =>
                info.scope == Operation && info.may_have_been_sent
              _ => false
            },
          )
          release.put(())
          while session.resources().abandoned > 0 {
            @async.pause()
          }
          assert_true(
            session.query_with_profile(
              "override",
              profile=@client.ExecutionProfile::new(timeout_ms=1),
              deadline=@client.Deadline::after(2000),
            )
            is Void,
          )
          assert_true(
            try {
              ignore(session.prepare("slow prepare"))
              false
            } catch {
              @client.TimedOut(info) =>
                info.scope == Operation && info.may_have_been_sent
              _ => false
            },
          )
          release.put(())
          while session.resources().abandoned > 0 {
            @async.pause()
          }
          assert_eq(session.resources().in_flight_bytes, 0L)
        },
      )
      worker.wait()
    })
  })
}

///|
async test "every simple page inherits retry policy while failed pages retain cursor and semantic profile binding" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let profile = @client.ExecutionProfile::new(
        consistency=Quorum,
        page_size=2,
        timeout_ms=500,
        retry=@client.RetryPolicy::new(max_attempts=2, delay_ms=0),
      )
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        for
          (state, failure, next) in [
            (None, false, Some(b"one")),
            (Some(b"one"), true, None),
            (Some(b"one"), false, Some(b"two")),
          ] {
          let actual = receive(peer)
          assert_eq(
            actual.body,
            @protocol.query("pages", options={
              ..profile.options(),
              paging_state: state,
            }).body,
          )
          respond(
            peer,
            actual.header.stream,
            if failure {
              0
            } else {
              8
            },
            if failure {
              overload_error()
            } else {
              rows_result([42], next)
            },
          )
        }
        let slow = receive(peer)
        release.get()
        respond(peer, slow.header.stream, 8, rows_result([99], None))
        let resumed = receive(peer)
        assert_eq(resumed.body, slow.body)
        respond(peer, resumed.header.stream, 8, rows_result([42], None))
        assert_eq(peer.read_some(), None)
      })
      @client.with_session_builder(
        config=@client.SessionBuilder::new(
          connection=@client.ConnectionBuilder::new(port=server.addr.port()),
          execution_profile=profile,
        ),
        session => {
          wait_session_nodes(session, 1)
          let pager = session.pages_with_options("pages", idempotent=true)
          assert_eq(pager.next().unwrap().row(0).int("id"), 42)
          assert_eq(pager.next_with_info().unwrap().info.attempt_count, 2)
          let before = pager.cursor().to_bytes()
          // 结果未知的超时即使允许重试，也不能重置整次取页的 Deadline。
          assert_true(
            try {
              ignore(pager.next())
              false
            } catch {
              @client.TimedOut(_) | @client.RetryExhausted(_) => true
              _ => false
            },
          )
          assert_eq(pager.cursor().to_bytes(), before)
          release.put(())
          while session.resources().abandoned > 0 {
            @async.pause()
          }
          let cursor = @client.PagingCursor::from_bytes(before)
          assert_true(
            try {
              ignore(
                session.pages_with_options(
                  "pages",
                  cursor~,
                  profile=@client.ExecutionProfile::new(
                    consistency=One,
                    page_size=2,
                  ),
                ),
              )
              false
            } catch {
              @client.Configuration(_) => true
              _ => false
            },
          )
          assert_true(
            try {
              ignore(
                session.pages_with_options(
                  "pages",
                  cursor~,
                  profile=@client.ExecutionProfile::new(
                    consistency=Quorum,
                    page_size=3,
                  ),
                ),
              )
              false
            } catch {
              @client.Configuration(_) => true
              _ => false
            },
          )
          let resumed = session.pages_with_options(
            "pages",
            cursor~,
            profile=@client.ExecutionProfile::new(
              consistency=Quorum,
              page_size=2,
              timeout_ms=2000,
            ),
          )
          assert_eq(resumed.next().unwrap().row(0).int("id"), 42)
          assert_true(resumed.next() is None)
        },
      )
      worker.wait()
    })
  })
}

///|
async test "prepared pages keep the selected profile and retry policy for each continuation" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let profile = @client.ExecutionProfile::new(
        consistency=Quorum,
        page_size=2,
        retry=@client.RetryPolicy::new(max_attempts=2, delay_ms=0),
      )
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let prepare = receive(peer)
        respond(peer, prepare.header.stream, 8, prepared_result(b"pages"))
        for state in [None, Some(b"one")] {
          for failure in [true, false] {
            let actual = receive(peer)
            assert_eq(
              actual.body,
              @protocol.execute(b"pages", b"metadata", [Integer(42)], options={
                ..profile.options(),
                paging_state: state,
              }).body,
            )
            respond(
              peer,
              actual.header.stream,
              if failure {
                0
              } else {
                8
              },
              if failure {
                overload_error()
              } else {
                rows_result(
                  [42],
                  if state is None {
                    Some(b"one")
                  } else {
                    None
                  },
                )
              },
            )
          }
        }
        assert_eq(peer.read_some(), None)
      })
      @client.with_session_builder(
        config=@client.SessionBuilder::new(
          connection=@client.ConnectionBuilder::new(port=server.addr.port()),
        ),
        session => {
          let statement = session.prepare_with_profile(
            "SELECT id FROM t WHERE id=?",
            profile~,
          )
          let pager = statement.pages_with_options(
            [Integer(42)],
            idempotent=true,
          )
          for _ in 0..<2 {
            let page = pager.next_with_info().unwrap()
            assert_eq(page.info.attempt_count, 2)
            assert_eq(page.value.row(0).int("id"), 42)
          }
          assert_true(pager.next() is None)
        },
      )
      worker.wait()
    })
  })
}

///|
async test "traversal budget starts on first page includes consumer time and cannot be extended by page deadline" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let profile = @client.ExecutionProfile::new(
        page_size=2,
        timeout_ms=2000,
        traversal_timeout_ms=500,
      )
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let first = receive(peer)
        respond(peer, first.header.stream, 8, rows_result([1], Some(b"one")))
        for
          (state, id, next_state) in [
            (b"one", 2, Some(b"two")),
            (b"two", 3, None),
          ] {
          let next = receive(peer)
          assert_eq(
            next.body,
            @protocol.query("traversal", options={
              ..profile.options(),
              paging_state: Some(state),
            }).body,
          )
          respond(peer, next.header.stream, 8, rows_result([id], next_state))
        }
        assert_eq(peer.read_some(), None)
      })
      @client.with_session_builder(
        config=@client.SessionBuilder::new(
          connection=@client.ConnectionBuilder::new(port=server.addr.port()),
        ),
        session => {
          let pager = session.pages_with_options("traversal", profile~)
          @async.sleep(600)
          assert_eq(pager.next().unwrap().row(0).int("id"), 1)
          let before = pager.cursor().to_bytes()
          @async.sleep(600)
          assert_true(
            try {
              ignore(pager.next(deadline=@client.Deadline::after(10000)))
              false
            } catch {
              @client.OperationTimedOut(WaitingPage, info) =>
                !info.may_have_been_sent
              _ => false
            },
          )
          assert_eq(pager.cursor().to_bytes(), before)
          let resumed = session.pages_with_options(
            "traversal",
            cursor=@client.PagingCursor::from_bytes(before),
            profile~,
            traversal_deadline=@client.Deadline::after(3000),
          )
          assert_eq(resumed.next().unwrap().row(0).int("id"), 2)
          // 显式整次期限替换相对遍历预算，但每页仍有自己的操作期限。
          @async.sleep(600)
          assert_eq(resumed.next().unwrap().row(0).int("id"), 3)
          assert_true(resumed.next() is None)
        },
      )
      worker.wait()
    })
  })
}

///|
async test "explicit traversal deadlines also bound connection and prepared pagers before any RPC" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let prepare = receive(peer)
        assert_eq(prepare.header.opcode, 9)
        respond(peer, prepare.header.stream, 8, prepared_result(b"expired"))
        let usable = receive(peer)
        assert_eq(@codec.Reader::new(usable.body).long_string(), "usable")
        respond(peer, usable.header.stream, 8, b"\x00\x00\x00\x01")
        assert_eq(peer.read_some(), None)
      })
      @client.with_connection_builder(
        config=@client.ConnectionBuilder::new(port=server.addr.port()),
        connection => {
          let statement = connection.prepare("SELECT id FROM t WHERE id=?")
          let deadline = @client.Deadline::after(1)
          let simple = connection.pages_with_options(
            "expired query",
            traversal_deadline=deadline,
          )
          let prepared = statement.pages_with_options(
            [Integer(42)],
            traversal_deadline=deadline,
          )
          @async.sleep(30)
          for pager in [simple, prepared] {
            let before = pager.cursor().to_bytes()
            assert_true(
              try {
                ignore(pager.next())
                false
              } catch {
                @client.OperationTimedOut(WaitingPage, info) =>
                  !info.may_have_been_sent
                _ => false
              },
            )
            assert_eq(pager.cursor().to_bytes(), before)
          }
          assert_true(connection.query("usable") is Void)
        },
      )
      worker.wait()
    })
  })
}

///|
test "invalid profiles fail before requests and returned options cannot change the original policy" {
  for
    invalid in [
      () => @client.ExecutionProfile::new(page_size=0),
      () => @client.ExecutionProfile::new(timeout_ms=0),
      () => @client.ExecutionProfile::new(traversal_timeout_ms=-1),
      () => @client.ExecutionProfile::new(serial_consistency=One),
      () => {
        @client.ExecutionProfile::new(
          retry=@client.RetryPolicy::new(max_attempts=0),
        )
      },
      () => {
        @client.ExecutionProfile::new(
          retry=@client.RetryPolicy::new(max_attempts=65),
        )
      },
      () => {
        @client.ExecutionProfile::new(
          retry=@client.RetryPolicy::new(delay_ms=-1),
        )
      },
    ] {
    assert_true(
      try {
        ignore(invalid())
        false
      } catch {
        @client.Configuration(_) => true
        _ => false
      },
    )
  }
  let profile = @client.ExecutionProfile::new(
    consistency=Quorum,
    page_size=2,
    timeout_ms=100,
    traversal_timeout_ms=200,
  )
  let changed = {
    ..profile.options(),
    consistency: @protocol.Consistency::All,
    page_size: Some(99),
  }
  assert_eq(changed.consistency, All)
  assert_eq(profile.options().consistency, Quorum)
  assert_eq(profile.options().page_size, Some(2))
  assert_eq(profile.timeout_ms(), Some(100))
  assert_eq(profile.traversal_timeout_ms(), Some(200))
  assert_eq(profile.retry_policy().max_attempts, 3)
}
