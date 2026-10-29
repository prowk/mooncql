///|
async test "pool auth failure and recovery create independent authentication sessions and stop every callback" {
  @async.with_timeout(7000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let creates = [0]
      let initial_calls = [0]
      let successes : Array[Int32] = []
      let worker = group.spawn(() => {
        @async.with_task_group(handlers => {
          for index in 1..<4 {
            let (tcp, _) = server.accept()
            ignore(
              handlers.spawn(() => {
                let peer = Peer::new(tcp)
                defer peer.close()
                auth_start(peer)
                let token = receive(peer)
                assert_eq(
                  @codec.Reader::new(token.body).bytes(),
                  Some(@utf8.encode("session-\{index}")),
                )
                if index == 1 {
                  let w = @codec.Writer::new()
                  w.i32(0x0100)
                  w.string("MARKER_AUTH_SECRET")
                  respond(peer, token.header.stream, 0, w.to_bytes())
                } else {
                  auth_token(peer, token.header.stream, 16, None)
                  while true {
                    let next = Some(receive(peer)) catch { _ => None }
                    guard next is Some(next) else { return }
                    respond(
                      peer,
                      next.header.stream,
                      8,
                      rows_result([index], None),
                    )
                  }
                }
              }),
            )
          }
        })
      })
      let provider = @client.AuthProvider::new((_, _) => {
        creates[0] += 1
        let nonce = creates[0]
        let initialized = [false]
        @client.Authenticator::new(
          () => {
            assert_true(!initialized[0])
            initialized[0] = true
            initial_calls[0] += 1
            Some(@utf8.encode("session-\{nonce}"))
          },
          on_success=_ => {
            assert_true(initialized[0])
            successes.push(nonce)
          },
        )
      })
      @client.with_session_builder(
        config=@client.SessionBuilder::new(
          connection=@client.ConnectionBuilder::new(
            port=server.addr.port(),
            auth_provider=provider,
            heartbeat_interval_ms=0,
          ),
          connections_per_node=2,
          jitter=0.0,
        ),
        session => {
          wait_pool_ready(session, 1, 2)
          assert_eq(creates[0], 3)
          assert_eq(initial_calls[0], 3)
          assert_eq(successes, [2, 3])
          let coordinators : Map[Int32, Bool] = Map([])
          for _ in 0..<12 {
            guard session.query("identify") is Rows(page) else {
              fail("missing row")
            }
            coordinators[page.row(0).int("id")] = true
          }
          assert_eq(coordinators.length(), 2)
          session.close()
          assert_eq(session.resources().background_task_handles, 0)
          assert_eq(session.budget().in_flight_bytes, 0L)
        },
      )
      worker.wait()
      let stopped = (creates[0], initial_calls[0], successes.length())
      for _ in 0..<4 {
        @async.pause()
      }
      assert_eq((creates[0], initial_calls[0], successes.length()), stopped)
    })
  })
}
