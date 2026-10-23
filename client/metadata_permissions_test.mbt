///|
async test "denied system metadata and discovery remain explicit while ordinary business queries continue" {
  for discover in [false, true] {
    @async.with_timeout(5000, () => {
      @async.with_task_group(group => {
        let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
        defer server.close()
        let worker = group.spawn(() => {
          @async.with_task_group(handlers => {
            while true {
              let accepted = Some(server.accept()) catch { _ => None }
              guard accepted is Some((tcp, _)) else { return }
              ignore(
                handlers.spawn(() => {
                  let peer = Peer::new(tcp)
                  defer peer.close()
                  handshake(peer)
                  while true {
                    let next = Some(receive(peer)) catch { _ => None }
                    guard next is Some(request) else { return }
                    if request.header.opcode == 11 {
                      respond(peer, request.header.stream, 2, b"")
                    } else {
                      let cql = @codec.Reader::new(request.body).long_string()
                      if cql.contains("FROM system") {
                        let error = @codec.Writer::new()
                        error.i32(0x2100)
                        error.string("system metadata is denied by test policy")
                        respond(
                          peer,
                          request.header.stream,
                          0,
                          error.to_bytes(),
                        )
                      } else {
                        respond(
                          peer,
                          request.header.stream,
                          8,
                          rows_result([42], None),
                        )
                      }
                    }
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
        @client.with_session(
          config=@client.SessionConfig::new(
            connection=@client.Config::new(
              port=server.addr.port(),
              heartbeat_interval_ms=0,
            ),
            discovery?=if discover {
              Some(@client.DiscoveryConfig::new())
            } else {
              None
            },
            backoff_initial_ms=10000,
            backoff_max_ms=10000,
            jitter=0.0,
          ),
          session => {
            guard session.query("SELECT id FROM app.business") is Rows(before) else {
              fail("missing business result")
            }
            assert_eq(before.row(0).int("id"), 42)
            assert_true(
              try {
                ignore(session.schema_metadata())
                false
              } catch {
                @client.SchemaMetadataError("version", @client.Server(error)) =>
                  error.code == 0x2100
                _ => false
              },
            )
            let agreement = session.wait_schema_agreement(
              deadline=@client.Deadline::after(500),
            )
            assert_eq(agreement.state, Unknown)
            assert_true(!agreement.timed_out)
            assert_true(
              agreement.observations.any(observation => {
                observation.error is Some(@client.Server(error)) &&
                error.code == 0x2100
              }),
            )
            if discover {
              while session.control_status().unwrap().last_error is None {
                @async.sleep(1)
              }
              assert_true(session.control_status().unwrap().stale)
              assert_true(
                session.control_status().unwrap().last_error
                is Some(@client.Server(error)) &&
                error.code == 0x2100,
              )
            }
            guard session.query("SELECT id FROM app.business") is Rows(after) else {
              fail("business was blocked by metadata denial")
            }
            assert_eq(after.row(0).int("id"), 42)
            ignore(session.drain(@client.Deadline::after(1000)))
            assert_eq(session.resources().background_task_handles, 0)
            assert_eq(session.budget().in_flight_bytes, 0L)
            assert_eq(session.budget().waiting, 0)
          },
        )
      })
    })
  }
}
