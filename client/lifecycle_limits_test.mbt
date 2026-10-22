///|
async test "authentication bounds and ambiguous credential settings fail before attempting TCP" {
  let provider = @client.AuthProvider::new((_, _) => {
    @client.Authenticator::new(() => None)
  })
  for
    config in [
      @client.Config::new(port=1, max_auth_rounds=0),
      @client.Config::new(port=1, max_auth_rounds=129),
      @client.Config::new(port=1, max_auth_token_bytes=-1),
      @client.Config::new(port=1, max_auth_token_bytes=16777217),
      @client.Config::new(
        port=1,
        auth_provider=provider,
        username="user",
        password="secret",
      ),
    ] {
    assert_true(
      try {
        @client.with_connection(config~, _ => ())
        false
      } catch {
        @client.Configuration(_) => true
        _ => false
      },
    )
  }
}

///|
async test "Connection drain reports deadline interruption and cancellation while joining active callers" {
  for mode in ["deadline", "immediate", "fault", "cancel"] {
    @async.with_timeout(5000, () => {
      @async.with_task_group(group => {
        let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
        defer server.close()
        let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
        let release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
        let worker = group.spawn(() => {
          let (tcp, _) = server.accept()
          let peer = Peer::new(tcp)
          defer peer.close()
          handshake(peer)
          ignore(receive(peer))
          seen.put(())
          if mode == "fault" {
            release.get()
          } else {
            assert_eq(peer.read_some(), None)
          }
        })
        @client.with_connection(
          config=@client.Config::new(port=server.addr.port()),
          connection => {
            @async.with_task_group(requests => {
              let task = requests.spawn(() => {
                try {
                  ignore(connection.query("in flight"))
                  false
                } catch {
                  _ => true
                }
              })
              seen.get()
              let drain = requests.spawn(() => {
                connection.drain(
                  @client.Deadline::after(
                    if mode == "deadline" {
                      50
                    } else {
                      2000
                    },
                  ),
                )
              })
              while !connection.is_draining() {
                @async.pause()
              }
              match mode {
                "immediate" => connection.close()
                "fault" => release.put(())
                "cancel" => drain.cancel()
                _ => ()
              }
              if mode == "cancel" {
                ignore(drain.wait()) catch {
                  _ => ()
                }
              } else {
                assert_eq(
                  drain.wait(),
                  if mode == "deadline" {
                    @client.DrainOutcome::DeadlineReached(1)
                  } else {
                    Interrupted(1)
                  },
                )
              }
              assert_true(task.wait())
              assert_true(connection.is_closed())
              assert_eq(connection.pending_count(), 0)
              assert_eq(connection.waiting_count(), 0)
              assert_eq(connection.in_flight_bytes(), 0L)
            })
          },
        )
        worker.wait()
      })
    })
  }
}
