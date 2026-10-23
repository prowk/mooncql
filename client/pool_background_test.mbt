///|
async test "one pooled heartbeat failure recycles only that connection while its healthy sibling serves" {
  @async.with_timeout(6000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let heartbeat_seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let failed : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let worker = group.spawn(() => {
        @async.with_task_group(handlers => {
          for index in 0..<2 {
            let (tcp, _) = server.accept()
            ignore(
              handlers.spawn(() => {
                let peer = Peer::new(tcp)
                defer peer.close()
                handshake(peer)
                while true {
                  let request = Some(receive(peer)) catch { _ => None }
                  guard request is Some(request) else { return }
                  if request.header.opcode == 5 {
                    if index == 0 {
                      heartbeat_seen.put(())
                      assert_eq(peer.read_some(), None)
                      failed.put(())
                      return
                    }
                    respond(
                      peer,
                      request.header.stream,
                      6,
                      heartbeat_supported(),
                    )
                  } else {
                    assert_eq(index, 1)
                    respond(
                      peer,
                      request.header.stream,
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
      @client.with_session(
        config=@client.SessionConfig::new(
          connection=@client.Config::new(
            port=server.addr.port(),
            max_in_flight=1,
            heartbeat_interval_ms=20,
            heartbeat_timeout_ms=200,
          ),
          connections_per_node=2,
          backoff_initial_ms=10000,
          backoff_max_ms=10000,
          jitter=0.0,
        ),
        session => {
          wait_pool_ready(session, 1, 2)
          heartbeat_seen.get()
          guard session.query("during sibling heartbeat") is Rows(first) else {
            fail("sibling heartbeat blocked healthy connection")
          }
          assert_eq(first.row(0).int("id"), 1)
          failed.get()
          while !session.pools()[0].connections.any(slot => {
                  slot.last_error is Some(@client.HeartbeatFailed)
                }) {
            @async.sleep(1)
          }
          assert_eq(session.status().state, Ready)
          assert_eq(session.pools()[0].ready, 1)
          guard session.query("after sibling heartbeat") is Rows(second) else {
            fail("healthy connection was recycled")
          }
          assert_eq(second.row(0).int("id"), 1)
          session.close()
          assert_eq(session.budget().in_flight, 0)
          assert_eq(session.resources().background_task_handles, 0)
        },
      )
      worker.wait()
    })
  })
}

///|
async test "topology removal closes every slot of the removed node and preserves the remaining pool and control connection" {
  @async.with_timeout(8000, () => {
    @async.with_task_group(group => {
      let servers = [
        @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0")),
        @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0")),
      ]
      defer (for server in servers {
        server.close()
      })
      let control_peer : @async.Queue[Peer] = @async.Queue(kind=Blocking(1))
      let include_peer = [true]
      let events = []
      let metrics = @client.Metrics::new(listener=event => events.push(event))
      let closed = [0, 0]
      let workers = []
      for index in 0..<2 {
        workers.push(
          group.spawn(() => {
            @async.with_task_group(handlers => {
              while true {
                let accepted = Some(servers[index].accept()) catch { _ => None }
                guard accepted is Some((tcp, _)) else { return }
                ignore(
                  handlers.spawn(() => {
                    let peer = Peer::new(tcp)
                    defer {
                      peer.close()
                      closed[index] += 1
                    }
                    handshake(peer)
                    while true {
                      let request = Some(receive(peer)) catch { _ => None }
                      guard request is Some(request) else { return }
                      if request.header.opcode == 11 {
                        respond(peer, request.header.stream, 2, b"")
                        control_peer.put(peer)
                      } else {
                        let cql = @codec.Reader::new(request.body).long_string()
                        let body = if cql.contains("FROM system.local") {
                          topology_rows(index, true, true)
                        } else if cql.contains("FROM system.peers_v2") {
                          topology_rows(1 - index, false, include_peer[0])
                        } else if cql.contains("FROM system_schema.keyspaces") {
                          replication_rows()
                        } else {
                          rows_result([index], None)
                        }
                        respond(peer, request.header.stream, 8, body)
                      }
                    }
                  }),
                )
              }
            })
          }),
        )
      }
      defer @async.protect_from_cancel(() => {
        for worker in workers {
          worker.cancel()
        }
        for worker in workers {
          ignore(worker.wait()) catch {
            _ => ()
          }
        }
      })
      @client.with_session(
        config=@client.SessionConfig::new(
          contact_points=[@client.Endpoint::new(port=servers[0].addr.port())],
          connection=@client.Config::new(heartbeat_interval_ms=0, metrics~),
          connections_per_node=2,
          discovery=@client.DiscoveryConfig::new(
            refresh_interval_ms=60000,
            debounce_ms=5,
            address_mapper=native => {
              let index = if native.address == b"\x0a\x00\x00\x01" {
                0
              } else {
                1
              }
              Some(@client.Endpoint::new(port=servers[index].addr.port()))
            },
          ),
        ),
        session => {
          let control = control_peer.get()
          ignore(wait_topology(session, 2, 1))
          wait_pool_ready(session, 2, 2)
          assert_eq(session.resources().cache_sizes.length(), 5)
          include_peer[0] = false
          let event = @codec.Writer::new()
          event.string("TOPOLOGY_CHANGE")
          event.string("REMOVED_NODE")
          event.u8(4)
          event.raw(b"\x0a\x00\x00\x02")
          event.i32(9042)
          respond(control, -1, 12, event.to_bytes())
          ignore(wait_topology(session, 1, 2))
          wait_pool_ready(session, 1, 2)
          while closed[1] != 2 {
            @async.sleep(1)
          }
          assert_eq(session.pools()[0].endpoint.port, servers[0].addr.port())
          assert_eq(session.resources().cache_sizes.length(), 3)
          guard session.query("remaining pool") is Rows(page) else {
            fail("remaining pool stopped after removal")
          }
          assert_eq(page.row(0).int("id"), 0)
          assert_true(
            events.any(event => {
              event is RequestFinished({ scope: Control, opcode: 11, .. })
            }),
          )
          assert_true(
            events.any(event => {
              event is RequestFinished({ scope: Control, opcode: 7, .. })
            }),
          )
          assert_true(
            events.any(event => {
              event is RequestFinished({ scope: Data, opcode: 7, .. })
            }),
          )
          session.close()
          assert_eq(session.resources().background_task_handles, 0)
          assert_eq(session.budget().in_flight, 0)
          assert_eq(session.budget().waiting_bytes, 0L)
        },
      )
    })
  })
}
