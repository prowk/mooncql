///|
fn schema_version_result(version : Bytes?) -> Bytes raise {
  let writer = @codec.Writer::new()
  writer.i32(2)
  writer.i32(1)
  writer.i32(1)
  writer.string("system")
  writer.string("local")
  writer.string("schema_version")
  writer.u16(12)
  writer.i32(1)
  @types.write_value(
    writer,
    match version {
      Some(version) => Uuid(version)
      None => Null
    },
  )
  writer.to_bytes()
}

///|
fn ddl_result() -> Bytes raise {
  let writer = @codec.Writer::new()
  writer.i32(5)
  writer.string("CREATED")
  writer.string("TYPE")
  writer.string("ks")
  writer.string("address")
  writer.to_bytes()
}

///|
async test "schema agreement distinguishes agreed divergent missing and replaced node versions" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let a = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      let b = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer a.close()
      defer b.close()
      let first = group.spawn(() => {
        let (tcp, _) = a.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        for _ in 0..<4 {
          let query = receive(peer)
          assert_eq(
            @codec.Reader::new(query.body).long_string(),
            "SELECT schema_version FROM system.local",
          )
          respond(
            peer,
            query.header.stream,
            8,
            schema_version_result(Some(b"aaaaaaaaaaaaaaaa")),
          )
        }
        assert_eq(peer.read_some(), None)
      })
      let second = group.spawn(() => {
        let (tcp, _) = b.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        for
          version in [
            Some(b"aaaaaaaaaaaaaaaa"),
            Some(b"bbbbbbbbbbbbbbbb"),
            None,
          ] {
          let query = receive(peer)
          respond(peer, query.header.stream, 8, schema_version_result(version))
        }
        // 最后一次检查期间断开该代连接，旧观察结果不得计作收敛。
        ignore(receive(peer))
      })
      @client.with_session(
        config=@client.SessionConfig::new(contact_points=[
          @client.Endpoint::new(port=a.addr.port()),
          @client.Endpoint::new(port=b.addr.port()),
        ]),
        session => {
          wait_session_nodes(session, 2)
          let agreed = session.check_schema_agreement()
          assert_eq(agreed.state, @client.SchemaAgreementState::Agreed)
          assert_eq(agreed.observations.length(), 2)
          assert_true(
            agreed.observations.all(observation => observation.generation == 1),
          )
          let divergent = session.check_schema_agreement()
          assert_eq(divergent.state, @client.SchemaAgreementState::Disagreed)
          divergent.observations.clear()
          let missing = session.check_schema_agreement()
          assert_eq(missing.state, @client.SchemaAgreementState::Unknown)
          assert_eq(missing.observations.length(), 2)
          assert_true(
            missing.observations.any(observation => {
              observation.version is None && observation.error is Some(_)
            }),
          )
          let replaced = session.check_schema_agreement()
          assert_eq(replaced.state, @client.SchemaAgreementState::Unknown)
          assert_true(replaced.membership_changed)
        },
      )
      first.wait()
      second.wait()
    })
  })
}

///|
async test "DDL waits for every live coordinator to converge before preparing a following statement" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let a = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      let b = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer a.close()
      defer b.close()
      let first = group.spawn(() => {
        let (tcp, _) = a.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let ddl = receive(peer)
        assert_eq(
          @codec.Reader::new(ddl.body).long_string(),
          "CREATE TYPE ks.address(street text)",
        )
        respond(peer, ddl.header.stream, 8, ddl_result())
        for _ in 0..<2 {
          let query = receive(peer)
          assert_eq(query.header.opcode, 7)
          respond(
            peer,
            query.header.stream,
            8,
            schema_version_result(Some(b"aaaaaaaaaaaaaaaa")),
          )
        }
        assert_eq(peer.read_some(), None)
      })
      let second = group.spawn(() => {
        let (tcp, _) = b.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        for version in [b"bbbbbbbbbbbbbbbb", b"aaaaaaaaaaaaaaaa"] {
          let query = receive(peer)
          assert_eq(
            @codec.Reader::new(query.body).long_string(),
            "SELECT schema_version FROM system.local",
          )
          respond(
            peer,
            query.header.stream,
            8,
            schema_version_result(Some(version)),
          )
        }
        let prepared = receive(peer)
        assert_eq(prepared.header.opcode, 9)
        respond(
          peer,
          prepared.header.stream,
          8,
          prepared_result(b"prepared-after-agreement"),
        )
        assert_eq(peer.read_some(), None)
      })
      @client.with_session(
        config=@client.SessionConfig::new(
          contact_points=[
            @client.Endpoint::new(port=a.addr.port()),
            @client.Endpoint::new(port=b.addr.port()),
          ],
          schema_agreement=@client.SchemaAgreementConfig::new(
            wait_after_ddl=true,
            poll_interval_ms=1,
          ),
        ),
        session => {
          wait_session_nodes(session, 2)
          let execution = session.query_with_info(
            "CREATE TYPE ks.address(street text)",
          )
          assert_true(execution.value is SchemaChanged(_))
          assert_true(
            execution.info.schema_agreement is Some(report) &&
            report.state == Agreed &&
            !report.timed_out,
          )
          assert_eq(execution.info.attempt_count, 1)
          ignore(session.prepare("SELECT street FROM ks.t WHERE id=?"))
        },
      )
      first.wait()
      second.wait()
    })
  })
}

///|
async test "schema wait shares total deadline and keeps successful DDL successful without replay" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let a = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      let b = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer a.close()
      defer b.close()
      let workers = []
      for
        (server, version, ddl) in [
          (a, b"aaaaaaaaaaaaaaaa", true),
          (b, b"bbbbbbbbbbbbbbbb", false),
        ] {
        workers.push(
          group.spawn(() => {
            let (tcp, _) = server.accept()
            let peer = Peer::new(tcp)
            defer peer.close()
            handshake(peer)
            if ddl {
              let request = receive(peer)
              @async.sleep(100)
              respond(peer, request.header.stream, 8, ddl_result())
            }
            while true {
              let request = Some(receive(peer)) catch {
                @io.ReaderClosed => None
                error => raise error
              }
              guard request is Some(request) else { break }
              assert_eq(request.header.opcode, 7)
              assert_eq(
                @codec.Reader::new(request.body).long_string(),
                "SELECT schema_version FROM system.local",
              )
              respond(
                peer,
                request.header.stream,
                8,
                schema_version_result(Some(version)),
              )
            }
          }),
        )
      }
      @client.with_session(
        config=@client.SessionConfig::new(
          contact_points=[
            @client.Endpoint::new(port=a.addr.port()),
            @client.Endpoint::new(port=b.addr.port()),
          ],
          schema_agreement=@client.SchemaAgreementConfig::new(
            wait_after_ddl=true,
            timeout_ms=2000,
            poll_interval_ms=5,
          ),
        ),
        session => {
          wait_session_nodes(session, 2)
          let started = @async.now()
          let execution = session.query_with_info(
            "CREATE TYPE ks.address(street text)",
            deadline=@client.Deadline::after(200),
            idempotent=true,
          )
          assert_true(execution.value is SchemaChanged(_))
          assert_eq(execution.info.attempt_count, 1)
          assert_true(
            execution.info.schema_agreement is Some(report) &&
            report.state != Agreed &&
            report.timed_out,
          )
          assert_true(@async.now() - started < 1000L)
          session.close()
          assert_eq(session.resources().active, 0)
          assert_eq(session.resources().pending, 0)
        },
      )
      for worker in workers {
        worker.wait()
      }
    })
  })
}

///|
async test "schema agreement reports unavailable empty membership and permission denial instead of pretending success" {
  @async.with_timeout(5000, () => {
    @client.with_session(
      config=@client.SessionConfig::new(connection=@client.Config::new(port=1)),
      session => {
        let report = session.check_schema_agreement()
        assert_eq(report.state, @client.SchemaAgreementState::Unknown)
        assert_eq(report.observations.length(), 0)
        assert_eq(report.excluded.length(), 1)
      },
    )
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let query = receive(peer)
        let error = @codec.Writer::new()
        error.i32(0x2100)
        error.string("metadata access denied")
        respond(peer, query.header.stream, 0, error.to_bytes())
        let marker = receive(peer)
        assert_eq(
          @codec.Reader::new(marker.body).long_string(),
          "ordinary query remains usable",
        )
        respond(peer, marker.header.stream, 8, b"\x00\x00\x00\x01")
        assert_eq(peer.read_some(), None)
      })
      @client.with_session(
        config=@client.SessionConfig::new(
          connection=@client.Config::new(port=server.addr.port()),
        ),
        session => {
          wait_session_nodes(session, 1)
          let started = @async.now()
          let report = session.wait_schema_agreement()
          assert_eq(report.state, @client.SchemaAgreementState::Unknown)
          assert_true(!report.timed_out)
          assert_true(
            report.observations[0].error is Some(@client.Server(error)) &&
            error.code == 0x2100,
          )
          assert_true(@async.now() - started < 1000L)
          assert_true(session.query("ordinary query remains usable") is Void)
        },
      )
      worker.wait()
    })
  })
}

///|
async test "schema agreement automatic waiting is opt in and bounds fail before connecting" {
  for
    schema_agreement in [
      @client.SchemaAgreementConfig::new(timeout_ms=0),
      @client.SchemaAgreementConfig::new(poll_interval_ms=0),
      @client.SchemaAgreementConfig::new(max_nodes=0),
    ] {
    assert_true(
      try {
        @client.with_session(
          config=@client.SessionConfig::new(schema_agreement~),
          _ => (),
        )
        false
      } catch {
        @client.Configuration(_) => true
        _ => false
      },
    )
  }
  @async.with_task_group(group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let worker = group.spawn(() => {
      let (tcp, _) = server.accept()
      let peer = Peer::new(tcp)
      defer peer.close()
      handshake(peer)
      let ddl = receive(peer)
      respond(peer, ddl.header.stream, 8, ddl_result())
      let marker = receive(peer)
      assert_eq(
        @codec.Reader::new(marker.body).long_string(),
        "no implicit metadata query",
      )
      respond(peer, marker.header.stream, 8, b"\x00\x00\x00\x01")
      assert_eq(peer.read_some(), None)
    })
    @client.with_session(
      config=@client.SessionConfig::new(
        connection=@client.Config::new(port=server.addr.port()),
      ),
      session => {
        let execution = session.query_with_info(
          "CREATE TYPE ks.address(street text)",
        )
        assert_true(execution.info.schema_agreement is None)
        assert_true(session.query("no implicit metadata query") is Void)
      },
    )
    worker.wait()
  })
}
