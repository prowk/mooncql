///|
async test "local control queue timeout or rejection retains healthy subscribed connection and later refreshes" {
  for policy in [@client.OverloadPolicy::Wait, Reject] {
    @async.with_timeout(6000, () => {
      @async.with_task_group(group => {
        let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
        defer server.close()
        let held : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
        let release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
        let accepted = [0]
        let registrations = [0]
        let business_completed = [0]
        let worker = group.spawn(() => {
          @async.with_task_group(handlers => {
            while true {
              let (tcp, _) = server.accept()
              accepted[0] += 1
              ignore(
                handlers.spawn(() => {
                  let peer = Peer::new(tcp)
                  defer peer.close()
                  handshake(peer)
                  while true {
                    let request = Some(receive(peer)) catch { _ => None }
                    guard request is Some(request) else { return }
                    if request.header.opcode == 11 {
                      registrations[0] += 1
                      respond(peer, request.header.stream, 2, b"")
                      continue
                    }
                    let cql = @codec.Reader::new(request.body).long_string()
                    let body = if cql == "held" {
                      held.put(())
                      release.get()
                      b"\x00\x00\x00\x01"
                    } else if cql == "traffic" {
                      business_completed[0] += 1
                      b"\x00\x00\x00\x01"
                    } else if cql.contains("FROM system.local") {
                      topology_rows(0, true, true)
                    } else if cql.contains("FROM system.peers_v2") {
                      topology_rows(1, false, false)
                    } else {
                      replication_rows()
                    }
                    respond(peer, request.header.stream, 8, body)
                  }
                }),
              )
            }
          })
        })
        defer @async.protect_from_cancel(() => {
          worker.cancel()
          ignore(worker.wait()) catch {
            _ => ()
          }
        })
        @client.with_session_builder(
          config=@client.SessionBuilder::new(
            connection=@client.ConnectionBuilder::new(
              port=server.addr.port(),
              queue_timeout_ms=20,
              heartbeat_interval_ms=0,
            ),
            limits=@client.SessionLimits::new(
              max_in_flight=1,
              overload_policy=policy,
            ),
            discovery=@client.DiscoveryConfig::new(refresh_interval_ms=20, address_mapper=_ => {
              Some(@client.Endpoint::new(port=server.addr.port()))
            }),
          ),
          session => {
            ignore(wait_topology(session, 1, 1))
            while session.budget().in_flight != 0 {
              @async.pause()
            }
            let before = session.control_status().unwrap()
            @async.with_task_group(requests => {
              let business = requests.spawn(() => session.query("held"))
              held.get()
              while session.control_status().unwrap().last_error is None {
                @async.pause()
              }
              let pressure = session.control_status().unwrap()
              assert_true(pressure.connected && pressure.stale)
              assert_eq(pressure.generation, before.generation)
              assert_eq(session.budget().in_flight, 1)
              assert_eq(accepted[0], 2)
              assert_eq(registrations[0], 1)
              assert_true(
                pressure.last_error is Some(@client.SessionOverloaded(_)) ||
                pressure.last_error is Some(@client.TimedOut(_)),
              )
              release.put(())
              assert_true(business.wait() is Void)
            })
            while session.control_status().unwrap().refreshes <=
                  before.refreshes ||
                  session.control_status().unwrap().stale {
              @async.pause()
            }
            assert_eq(
              session.control_status().unwrap().generation,
              before.generation,
            )
            assert_eq(accepted[0], 2)
            assert_eq(registrations[0], 1)
            if policy == Wait {
              let refreshes = session.control_status().unwrap().refreshes
              let stop = [false]
              @async.with_task_group(traffic => {
                let workers = []
                for _ in 0..<16 {
                  workers.push(
                    traffic.spawn(() => {
                      while !stop[0] {
                        ignore(session.query("traffic")) catch {
                          @client.TimedOut(info) =>
                            assert_true(!info.may_have_been_sent)
                          error => raise error
                        }
                        assert_true(session.budget().in_flight <= 1)
                      }
                    }),
                  )
                }
                while session.control_status().unwrap().refreshes <
                      refreshes + 3 {
                  @async.pause()
                }
                stop[0] = true
                for worker in workers {
                  worker.wait()
                }
              })
              assert_true(business_completed[0] >= 16)
              assert_eq(registrations[0], 1)
              assert_eq(accepted[0], 2)
            }
            assert_eq(
              session.drain(@client.Deadline::after(2000)),
              @client.DrainOutcome::Drained,
            )
            assert_eq(session.budget().in_flight, 0)
            assert_eq(session.budget().waiting, 0)
            assert_eq(session.scheduling().queued, 0)
          },
        )
      })
    })
  }
}
