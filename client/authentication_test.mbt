///|
async fn auth_start(peer : Peer) -> Unit {
  let options = receive(peer)
  assert_eq(options.header.opcode, 5)
  let supported = @codec.Writer::new()
  supported.u16(if peer.compressed { 2 } else { 1 })
  supported.string("CQL_VERSION")
  supported.u16(1)
  supported.string("3.0.0")
  if peer.compressed {
    supported.string("COMPRESSION")
    supported.u16(1)
    supported.string("lz4")
  }
  respond(peer, options.header.stream, 6, supported.to_bytes())
  let startup = receive(peer)
  assert_eq(startup.header.opcode, 1)
  let body = @codec.Writer::new()
  body.string("test.authenticator")
  respond(peer, startup.header.stream, 3, body.to_bytes())
  peer.framed = true
}

///|
async fn auth_token(
  peer : Peer,
  stream : Int,
  opcode : Int,
  token : Bytes?,
) -> Unit {
  let body = @codec.Writer::new()
  body.bytes(token)
  respond(peer, stream, opcode, body.to_bytes())
}

///|
async test "custom auth handles bounded multiround NULL and empty tokens under plain and LZ4 framing" {
  for compressed in [false, true] {
    @async.with_timeout(3000, () => {
      @async.with_task_group(group => {
        let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
        defer server.close()
        let successes = [0]
        let worker = group.spawn(() => {
          let (tcp, _) = server.accept()
          let peer = Peer::new(tcp, compressed~)
          defer peer.close()
          auth_start(peer)
          for
            (expected, challenge) in [
              (Some(b"init"), Some(b"one")),
              (Some(b""), None),
            ] {
            let response = receive(peer)
            assert_eq(response.header.opcode, 15)
            assert_eq(@codec.Reader::new(response.body).bytes(), expected)
            auth_token(peer, response.header.stream, 14, challenge)
          }
          let response = receive(peer)
          assert_eq(@codec.Reader::new(response.body).bytes(), None)
          auth_token(peer, response.header.stream, 16, Some(b"done"))
          let query = receive(peer)
          respond(peer, query.header.stream, 8, b"\x00\x00\x00\x01")
          assert_eq(peer.read_some(), None)
        })
        let provider = @client.AuthProvider::new((name, endpoint) => {
          assert_eq(name, "test.authenticator")
          assert_eq(endpoint.port, server.addr.port())
          @client.Authenticator::new(
            () => Some(b"init"),
            evaluate_challenge=challenge => {
              if challenge == Some(b"one") {
                Some(b"")
              } else {
                None
              }
            },
            on_success=token => {
              assert_eq(token, Some(b"done"))
              successes[0] += 1
            },
          )
        })
        @client.with_connection_builder(
          config=@client.ConnectionBuilder::new(
            port=server.addr.port(),
            compression=compressed,
            auth_provider=provider,
            max_auth_rounds=3,
            max_auth_token_bytes=4,
          ),
          connection => assert_true(connection.query("ready") is Void),
        )
        assert_eq(successes[0], 1)
        worker.wait()
      })
    })
  }
}

///|
async test "authentication rejects excessive rounds oversized tokens server refusal and provider errors without leaking credentials" {
  for
    mode in [
      "outbound", "challenge", "success", "rounds", "failure", "callback_error",
      "initial_error", "success_error",
    ] {
    @async.with_timeout(3000, () => {
      @async.with_task_group(group => {
        let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
        defer server.close()
        let worker = group.spawn(() => {
          let (tcp, _) = server.accept()
          let peer = Peer::new(tcp)
          defer peer.close()
          auth_start(peer)
          if mode != "outbound" && mode != "initial_error" {
            let response = receive(peer)
            assert_eq(response.header.opcode, 15)
            if mode == "failure" {
              let error = @codec.Writer::new()
              error.i32(0x0100)
              error.string("secret-auth-token password")
              respond(peer, response.header.stream, 0, error.to_bytes())
            } else if mode == "success_error" {
              auth_token(peer, response.header.stream, 16, None)
            } else if mode == "success" {
              auth_token(peer, response.header.stream, 16, Some(b"12345"))
            } else {
              auth_token(
                peer,
                response.header.stream,
                14,
                Some(if mode == "challenge" { b"12345" } else { b"c" }),
              )
              if mode == "rounds" {
                let response = receive(peer)
                assert_eq(response.header.opcode, 15)
                auth_token(peer, response.header.stream, 14, Some(b"c"))
              }
            }
          }
          assert_eq(peer.read_some(), None)
        })
        let provider = @client.AuthProvider::new((_, _) => {
          @client.Authenticator::new(
            () => {
              if mode == "initial_error" {
                fail("secret-auth-token password")
              } else {
                Some(if mode == "outbound" { b"12345" } else { b"init" })
              }
            },
            evaluate_challenge=_ => {
              if mode == "callback_error" {
                fail("secret-auth-token password")
              } else {
                Some(b"r")
              }
            },
            on_success=_ => {
              if mode == "success_error" {
                fail("secret-auth-token password")
              }
            },
          )
        })
        let events = []
        let metrics = @client.Metrics::with_diagnostics(event => {
          events.push(event)
        })
        assert_true(
          try {
            @client.with_connection_builder(
              config=@client.ConnectionBuilder::new(
                port=server.addr.port(),
                auth_provider=provider,
                max_auth_rounds=2,
                max_auth_token_bytes=4,
                metrics~,
              ),
              _ => (),
            )
            false
          } catch {
            @client.Authentication(message) =>
              !message.contains("secret-auth-token") &&
              !message.contains("password")
            _ => false
          },
        )
        assert_true(
          events.any(event => event is ConnectionFailure(_, OtherFailure, true)),
        )
        worker.wait()
      })
    })
  }
}

///|
async test "auth provider callbacks and challenge exchanges share connection deadline and cancellation closes the socket" {
  for cancel in [false, true] {
    @async.with_timeout(3000, () => {
      @async.with_task_group(group => {
        let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
        defer server.close()
        let entered : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
        let blocked : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
        let worker = group.spawn(() => {
          let (tcp, _) = server.accept()
          let peer = Peer::new(tcp)
          defer peer.close()
          auth_start(peer)
          let response = receive(peer)
          auth_token(peer, response.header.stream, 14, Some(b"challenge"))
          assert_eq(peer.read_some(), None)
        })
        let provider = @client.AuthProvider::new((_, _) => {
          @client.Authenticator::new(
            () => {
              @async.sleep(100)
              Some(b"init")
            },
            evaluate_challenge=_ => {
              entered.put(())
              blocked.get()
              None
            },
          )
        })
        let config = @client.ConnectionBuilder::new(
          port=server.addr.port(),
          auth_provider=provider,
          connect_timeout_ms=if cancel { 2000 } else { 200 },
        )
        if cancel {
          let task = group.spawn(() => {
            @client.with_connection_builder(config~, _ => ())
          })
          entered.get()
          task.cancel()
          ignore(task.wait()) catch {
            _ => ()
          }
        } else {
          let started = @async.now()
          assert_true(
            try {
              @client.with_connection_builder(config~, _ => ())
              false
            } catch {
              @client.TimedOut(info) => info.scope == Connection
              _ => false
            },
          )
          assert_true(@async.now() - started < 1000L)
        }
        worker.wait()
      })
    })
  }
}

///|
async test "auth factory snapshots rotated credentials per new connection without interrupting old in-flight requests" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let credentials = [b"old"]
      let creates = [0]
      let worker = group.spawn(() => {
        {
          let (tcp, _) = server.accept()
          let peer = Peer::new(tcp)
          defer peer.close()
          auth_start(peer)
          let response = receive(peer)
          assert_eq(@codec.Reader::new(response.body).bytes(), Some(b"old"))
          auth_token(peer, response.header.stream, 16, None)
          let request = receive(peer)
          credentials[0] = b"new"
          respond(peer, request.header.stream, 8, named_result("old"))
          let request = receive(peer)
          respond(peer, request.header.stream, 8, named_result("still old"))
          ignore(receive(peer))
        }
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        auth_start(peer)
        let response = receive(peer)
        assert_eq(@codec.Reader::new(response.body).bytes(), Some(b"new"))
        auth_token(peer, response.header.stream, 16, None)
        let request = receive(peer)
        assert_eq(
          @codec.Reader::new(request.body).long_string(),
          "explicit new query",
        )
        respond(peer, request.header.stream, 8, named_result("new"))
        assert_eq(peer.read_some(), None)
      })
      let provider = @client.AuthProvider::new((_, _) => {
        creates[0] += 1
        let token = credentials[0]
        @client.Authenticator::new(() => Some(token))
      })
      @client.with_session_builder(
        config=@client.SessionBuilder::new(
          connection=@client.ConnectionBuilder::new(
            port=server.addr.port(),
            auth_provider=provider,
          ),
        ),
        session => {
          assert_true(session.query("first") is SetKeyspace("old"))
          assert_true(session.query("second") is SetKeyspace("still old"))
          assert_true(
            try {
              ignore(session.query("disconnect"))
              false
            } catch {
              _ => true
            },
          )
          assert_true(session.query("explicit new query") is SetKeyspace("new"))
          assert_eq(creates[0], 2)
        },
      )
      worker.wait()
    })
  })
}
