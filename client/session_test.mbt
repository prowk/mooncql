///|
async test "session replaces a disconnected connection without replaying the failed write" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        {
          let (tcp, _) = server.accept()
          let peer = Peer::new(tcp)
          defer peer.close()
          handshake(peer)
          let query = receive(peer)
          assert_eq(@codec.Reader::new(query.body).long_string(), "write once")
          // 服务端在收到写入后断开，驱动不能知道写入是否已经生效。
        }
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let query = receive(peer)
        assert_eq(@codec.Reader::new(query.body).long_string(), "after restart")
        respond(peer, query.header.stream, 8, named_result("recovered"))
        assert_eq(peer.read_some(), None)
      })
      @client.with_session(
        config=@client.SessionConfig::new(
          connection=@client.Config::new(port=server.addr.port()),
        ),
        session => {
          assert_true(
            try {
              ignore(session.query("write once"))
              false
            } catch {
              _ => true
            },
          )
          assert_true(
            session.query("after restart") is SetKeyspace("recovered"),
          )
          assert_eq(session.status().generation, 2)
          assert_eq(session.status().state, Ready)
          session.close()
          assert_true(session.is_closed())
          assert_eq(session.status().state, Stopped)
          assert_eq(session.waiting_count(), 0)
          assert_eq(session.active_count(), 0)
        },
      )
      worker.wait()
    })
  })
}

///|
async test "closing session cancels a stalled connect and wakes all connection waiters" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        assert_eq(receive(peer).header.opcode, 5)
        seen.put(())
        assert_eq(peer.read_some(), None)
      })
      @client.with_session(
        config=@client.SessionConfig::new(
          connection=@client.Config::new(port=server.addr.port(), max_waiting=2),
        ),
        session => {
          @async.with_task_group(requests => {
            async fn send() {
              try {
                ignore(session.query("waiting"))
                false
              } catch {
                @client.Closed => true
                _ => false
              }
            }
            let first = requests.spawn(send)
            seen.get()
            let second = requests.spawn(send)
            while session.waiting_count() != 2 {
              @async.pause()
            }
            assert_true(
              try {
                ignore(session.query("excess"))
                false
              } catch {
                @client.Overloaded(WaitingQueueFull) => true
                _ => false
              },
            )
            session.close()
            assert_true(first.wait())
            assert_true(second.wait())
          })
          assert_eq(session.status().state, Stopped)
          assert_eq(session.active_count(), 0)
          assert_eq(session.waiting_count(), 0)
          assert_true(
            try {
              ignore(session.query("closed"))
              false
            } catch {
              @client.Closed => true
              _ => false
            },
          )
        },
      )
      worker.wait()
    })
  })
}

///|
async test "unavailable session retries with bounded backoff and respects the caller deadline" {
  @async.with_timeout(5000, () => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    let port = server.addr.port()
    server.close()
    @client.with_session(
      config=@client.SessionConfig::new(
        connection=@client.Config::new(port~, connect_timeout_ms=100),
        backoff_initial_ms=40,
        backoff_max_ms=100,
        jitter=0.25,
      ),
      session => {
        assert_true(
          try {
            ignore(
              session.query(
                "unavailable",
                deadline=@client.Deadline::after(450),
              ),
            )
            false
          } catch {
            @client.TimedOut(info) =>
              info.phase == WaitingConnection &&
              info.scope == Operation &&
              !info.may_have_been_sent
            _ => false
          },
        )
        assert_true(session.status().attempts >= 2)
        assert_true(session.status().attempts <= 10)
        assert_true(session.last_error() is Some(_))
        assert_eq(session.active_count(), 0)
        assert_eq(session.waiting_count(), 0)
        session.close()
        assert_eq(session.status().state, Stopped)
      },
    )
  })
}

///|
async test "scope exit joins idle session recovery and rejects use after scope" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let query = receive(peer)
        respond(peer, query.header.stream, 8, b"\x00\x00\x00\x01")
        assert_eq(peer.read_some(), None)
      })
      let escaped = @client.with_session(
        config=@client.SessionConfig::new(
          connection=@client.Config::new(port=server.addr.port()),
        ),
        session => {
          assert_true(session.query("healthy") is Void)
          session
        },
      )
      assert_true(escaped.is_closed())
      assert_eq(escaped.status().state, Stopped)
      assert_true(
        try {
          ignore(escaped.query("closed"))
          false
        } catch {
          @client.Closed => true
          _ => false
        },
      )
      worker.wait()
    })
  })
}
