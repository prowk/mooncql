///|
async test "schema notifications invalidate on-demand cache and merge burst refreshes without exposing live containers" {
  @async.with_timeout(7000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let control_peer : @async.Queue[Peer] = @async.Queue(kind=Blocking(1))
      let changed = [false]
      let catalogs = [0]
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
                  let request = Some(receive(peer)) catch { _ => None }
                  guard request is Some(request) else { return }
                  if request.header.opcode == 11 {
                    respond(peer, request.header.stream, 2, b"")
                    control_peer.put(peer)
                  } else {
                    let cql = @codec.Reader::new(request.body).long_string()
                    let body = if cql.contains("SELECT schema_version FROM") {
                      // 故意保持版本相同，单独证明事件会使缓存失效。
                      schema_version_result(Some(b"aaaaaaaaaaaaaaaa"))
                    } else if cql.contains("FROM system.local") {
                      topology_rows(0, true, true)
                    } else if cql.contains("FROM system.peers_v2") {
                      topology_rows(1, false, false)
                    } else if cql.contains("system_schema.keyspaces") &&
                      !cql.contains("durable_writes") {
                      replication_rows()
                    } else {
                      catalogs[0] += 1
                      ignore(schema_filter(request))
                      schema_fixture(cql, changed=changed[0])
                    }
                    respond(peer, request.header.stream, 8, body)
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
      @client.with_session_builder(
        config=@client.SessionBuilder::new(
          connection=@client.ConnectionBuilder::new(
            port=server.addr.port(),
            event_capacity=64,
          ),
          discovery=@client.DiscoveryConfig::new(
            refresh_interval_ms=60000,
            debounce_ms=30,
            address_mapper=_ => {
              Some(@client.Endpoint::new(port=server.addr.port()))
            },
          ),
        ),
        session => {
          let control = control_peer.get()
          ignore(wait_topology(session, 1, 1))
          wait_session_nodes(session, 1)
          let options = @client.SchemaOptions::new(keyspaces=["ks"])
          let before = session.schema_metadata(options~)
          ignore(session.schema_metadata(options~))
          assert_eq(catalogs[0], 5)
          let revision = session.control_status().unwrap().refreshes
          changed[0] = true
          let event = @codec.Writer::new()
          for text in ["SCHEMA_CHANGE", "UPDATED", "TYPE", "ks", "address"] {
            event.string(text)
          }
          let burst = @codec.Writer::new()
          for _ in 0..<32 {
            burst.raw(
              @protocol.encode_envelope(-1, 12, event.to_bytes(), response=true),
            )
          }
          control.write(@framing.encode(burst.to_bytes()))
          @async.with_timeout(3000, () => {
            while session.control_status().unwrap().refreshes <= revision ||
                  session.control_status().unwrap().stale {
              @async.sleep(5)
            }
          })
          let refreshed = @async.all([
            () => session.schema_metadata(options~),
            () => session.schema_metadata(options~),
          ])
          assert_eq(catalogs[0], 10)
          assert_true(
            session.control_status().unwrap().refreshes - revision <= 2,
          )
          assert_eq(
            refreshed[0].user_type("ks", "address").unwrap().fields.length(),
            3,
          )
          assert_eq(
            refreshed[1].table("ks", "events").unwrap().columns.length(),
            6,
          )
          assert_eq(
            before.user_type("ks", "address").unwrap().fields.length(),
            2,
          )
          session.close()
          assert_eq(session.resources().background_task_handles, 0)
        },
      )
    })
  })
}

///|
async test "schema changes during load retry consistently and repeated changes fail with no partial snapshot" {
  for mode in ["once", "always", "incomplete-then-changed"] {
    @async.with_timeout(5000, () => {
      @async.with_task_group(group => {
        let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
        defer server.close()
        let versions = [0]
        let incomplete = [false]
        let worker = group.spawn(() => {
          let (tcp, _) = server.accept()
          let peer = Peer::new(tcp)
          defer peer.close()
          handshake(peer)
          while true {
            let request = Some(receive(peer)) catch { _ => None }
            guard request is Some(request) else { return }
            let cql = @codec.Reader::new(request.body).long_string()
            let body = if cql.contains("schema_version FROM") {
              versions[0] += 1
              schema_version_result(
                Some(
                  if versions[0] == 1 ||
                    (mode == "always" && versions[0] % 2 == 1) {
                    b"aaaaaaaaaaaaaaaa"
                  } else {
                    b"bbbbbbbbbbbbbbbb"
                  },
                ),
              )
            } else {
              ignore(schema_filter(request))
              if mode == "incomplete-then-changed" &&
                !incomplete[0] &&
                cql.contains("system_schema.columns") {
                incomplete[0] = true
                schema_fixture(cql, mode="missing-columns")
              } else {
                schema_fixture(cql, changed=versions[0] >= 2)
              }
            }
            respond(peer, request.header.stream, 8, body)
          }
        })
        @client.with_session_builder(
          config=@client.SessionBuilder::new(
            connection=@client.ConnectionBuilder::new(port=server.addr.port()),
          ),
          session => {
            if mode == "always" {
              assert_true(
                try {
                  ignore(
                    session.schema_metadata(
                      options=@client.SchemaOptions::new(keyspaces=["ks"]),
                    ),
                  )
                  false
                } catch {
                  @client.SchemaMetadataError("changed", _) => true
                  _ => false
                },
              )
              assert_eq(versions[0], 6)
            } else {
              let snapshot = session.schema_metadata(
                options=@client.SchemaOptions::new(keyspaces=["ks"]),
              )
              assert_eq(snapshot.schema_version(), b"bbbbbbbbbbbbbbbb")
              assert_eq(
                snapshot.user_type("ks", "address").unwrap().fields.length(),
                3,
              )
              assert_eq(versions[0], 4)
            }
            assert_eq(session.resources().active, 0)
          },
        )
        worker.wait()
      })
    })
  }
}

///|
async test "schema waiters honor deadlines cancellation count and byte limits without retaining queue credits" {
  for mode in ["timeout", "cancel", "count", "bytes"] {
    @async.with_timeout(5000, () => {
      @async.with_task_group(group => {
        let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
        defer server.close()
        let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
        let release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
        let versions = [0]
        let worker = group.spawn(() => {
          let (tcp, _) = server.accept()
          let peer = Peer::new(tcp)
          defer peer.close()
          handshake(peer)
          while true {
            let request = Some(receive(peer)) catch { _ => None }
            guard request is Some(request) else { return }
            let cql = @codec.Reader::new(request.body).long_string()
            let body = if cql.contains("schema_version FROM") {
              versions[0] += 1
              if versions[0] == 1 {
                seen.put(())
                release.get()
              }
              schema_version_result(Some(b"aaaaaaaaaaaaaaaa"))
            } else {
              schema_fixture(cql)
            }
            respond(peer, request.header.stream, 8, body)
          }
        })
        @client.with_session_builder(
          config=@client.SessionBuilder::new(
            connection=@client.ConnectionBuilder::new(
              port=server.addr.port(),
              max_waiting=1,
              max_waiting_bytes=if mode == "bytes" { 0 } else { 4096 },
            ),
          ),
          session => {
            wait_session_nodes(session, 1)
            @async.with_task_group(requests => {
              let options = @client.SchemaOptions::new(keyspaces=["ks"])
              let owner = requests.spawn(() => session.schema_metadata(options~))
              seen.get()
              if mode == "timeout" {
                assert_true(
                  try {
                    ignore(
                      session.schema_metadata(
                        options~,
                        deadline=@client.Deadline::after(30),
                      ),
                    )
                    false
                  } catch {
                    @client.OperationTimedOut(WaitingSchema, info) =>
                      !info.may_have_been_sent
                    _ => false
                  },
                )
              } else if mode == "bytes" {
                assert_true(
                  try {
                    ignore(session.schema_metadata(options~))
                    false
                  } catch {
                    @client.Overloaded(WaitingBytesFull) => true
                    _ => false
                  },
                )
              } else {
                let waiter = requests.spawn(() => {
                  session.schema_metadata(options~)
                })
                while session.waiting_count() == 0 {
                  @async.pause()
                }
                if mode == "count" {
                  assert_true(
                    try {
                      ignore(session.schema_metadata(options~))
                      false
                    } catch {
                      @client.Overloaded(WaitingQueueFull) => true
                      _ => false
                    },
                  )
                }
                waiter.cancel()
                ignore(waiter.wait()) catch {
                  _ => ()
                }
              }
              assert_eq(session.waiting_count(), 0)
              assert_eq(session.resources().waiting_bytes, 0L)
              release.put(())
              ignore(owner.wait())
              assert_eq(versions[0], 2)
            })
          },
        )
        worker.wait()
      })
    })
  }
}

///|
test "schema options enforce finite unambiguous request definitions before allocating a metadata operation" {
  for keyspaces in [[""], ["ks", "ks"], ["bad\u0000name"]] {
    assert_true(
      try {
        ignore(@client.SchemaOptions::new(keyspaces~))
        false
      } catch {
        @client.Configuration(_) => true
        _ => false
      },
    )
  }
  assert_true(
    try {
      ignore(@client.SchemaOptions::new(max_keyspaces=0))
      false
    } catch {
      @client.Configuration(_) => true
      _ => false
    },
  )
  assert_true(
    try {
      ignore(@client.SchemaOptions::new(max_columns=1000001))
      false
    } catch {
      @client.Configuration(_) => true
      _ => false
    },
  )
  assert_true(
    try {
      ignore(@client.SchemaOptions::new(max_bytes=255))
      false
    } catch {
      @client.Configuration(_) => true
      _ => false
    },
  )
}
