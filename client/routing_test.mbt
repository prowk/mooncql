///|
async fn with_routing_fixture(
  local_dc : String,
  allow_remote? : Bool = false,
  remote_dc? : Bool = false,
  expired? : Bool = false,
  unsupported? : Bool = false,
  local_in_flight? : Int = 128,
  held? : @async.Queue[Unit],
  release? : @async.Queue[Unit],
  body : async (@client.Session, Int, Int) -> Unit,
) -> Unit {
  @async.with_timeout(6000, () => {
    @async.with_task_group(group => {
      let servers = [
        @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0")),
        @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0")),
      ]
      defer (for server in servers {
        server.close()
      })
      let workers = []
      let local_unavailable = [false]
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
                    defer peer.close()
                    if index == 0 && local_unavailable[0] {
                      return
                    }
                    handshake(peer)
                    while true {
                      let request = Some(receive(peer)) catch { _ => None }
                      guard request is Some(request) else { return }
                      if request.header.opcode == 11 {
                        respond(peer, request.header.stream, 2, b"")
                      } else if request.header.opcode == 9 {
                        respond(
                          peer,
                          request.header.stream,
                          8,
                          session_metadata(
                            if index == 0 {
                              b"a"
                            } else {
                              b"b"
                            },
                            b"metadata",
                            "id",
                          ),
                        )
                      } else if request.header.opcode == 10 {
                        let r = @codec.Reader::new(request.body)
                        assert_eq(
                          r.short_bytes(),
                          if index == 0 {
                            b"a"
                          } else {
                            b"b"
                          },
                        )
                        assert_eq(index, 1)
                        respond(peer, request.header.stream, 8, session_row(7))
                      } else {
                        let cql = @codec.Reader::new(request.body).long_string()
                        if cql == "disconnect local" && index == 0 {
                          local_unavailable[0] = true
                          return
                        }
                        if cql == "hold candidate" || cql == "next candidate" {
                          let reader = @codec.Reader::new(request.body)
                          ignore(reader.long_string())
                          assert_eq(reader.u16(), 6)
                          assert_eq(reader.i32(), 0)
                          reader.finish()
                          if cql == "hold candidate" &&
                            held is Some(held) &&
                            release is Some(release) {
                            held.put(())
                            release.get()
                          }
                        }
                        let is_local = cql.contains("FROM system.local")
                        let body = if is_local ||
                          cql.contains("FROM system.peers_v2") {
                          let owner = if is_local { index } else { 1 - index }
                          topology_rows(
                            owner,
                            is_local,
                            true,
                            data_center=if remote_dc && owner == 1 {
                              "dc2"
                            } else {
                              "dc1"
                            },
                            wide_tokens=true,
                            partitioner=if unsupported {
                              "org.apache.cassandra.dht.RandomPartitioner"
                            } else {
                              "org.apache.cassandra.dht.Murmur3Partitioner"
                            },
                          )
                        } else if cql.contains("FROM system_schema.keyspaces") {
                          replication_rows(simple=true)
                        } else {
                          named_result("node\{index}")
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
          connection=@client.Config::new(max_in_flight=local_in_flight),
          contact_points=[@client.Endpoint::new(port=servers[0].addr.port())],
          discovery=@client.DiscoveryConfig::new(refresh_interval_ms=10000, address_mapper=native => {
            let index = if native.address == b"\x0a\x00\x00\x01" {
              0
            } else {
              1
            }
            Some(@client.Endpoint::new(port=servers[index].addr.port()))
          }),
          routing=@client.RoutingConfig::new(
            local_dc,
            allow_remote~,
            max_metadata_age_ms=if expired { 1 } else { 60000 },
          ),
          backoff_initial_ms=10000,
          backoff_max_ms=10000,
          jitter=0.0,
        ),
        session => {
          ignore(wait_topology(session, 2, 1))
          wait_session_nodes(session, 2)
          body(session, servers[0].addr.port(), servers[1].addr.port())
          session.close()
          assert_eq(session.active_count(), 0)
          assert_eq(session.waiting_count(), 0)
        },
      )
    })
  })
}

///|
async test "disconnected local DC obeys explicit remote fallback without changing LOCAL_QUORUM" {
  for allow_remote in [false, true] {
    with_routing_fixture("dc1", allow_remote~, remote_dc=true, (session, _, b) => {
      let options = @protocol.QueryOptions::new(consistency=LocalQuorum)
      assert_true(
        try {
          ignore(session.query("disconnect local", options~))
          false
        } catch {
          _ => true
        },
      )
      @async.with_timeout(1000, () => {
        while session
              .nodes()
              .filter(node => node.status.state == Ready)
              .length() !=
              1 {
          @async.sleep(1)
        }
      })
      if allow_remote {
        assert_eq(session.query_plan()[0].port, b)
        assert_true(
          session.query("next candidate", options~) is SetKeyspace("node1"),
        )
      } else {
        assert_eq(session.query_plan().length(), 0)
        assert_true(
          try {
            ignore(
              session.query(
                "next candidate",
                options~,
                deadline=@client.Deadline::after(30),
              ),
            )
            false
          } catch {
            @client.TimedOut(info) => !info.may_have_been_sent
            _ => false
          },
        )
      }
    })
  }
}

///|
async test "saturated local DC obeys explicit remote fallback and preserves LOCAL_QUORUM on the wire" {
  for allow_remote in [false, true] {
    let held : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
    let release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
    with_routing_fixture(
      "dc1",
      allow_remote~,
      remote_dc=true,
      local_in_flight=1,
      held~,
      release~,
      (session, _, _) => {
        @async.with_task_group(requests => {
          let options = @protocol.QueryOptions::new(consistency=LocalQuorum)
          let owner = requests.spawn(() => {
            session.query("hold candidate", options~)
          })
          held.get()
          if allow_remote {
            assert_true(
              session.query("next candidate", options~) is SetKeyspace("node1"),
            )
            release.put(())
          } else {
            let queued = requests.spawn(() => {
              session.query("next candidate", options~)
            })
            @async.sleep(30)
            assert_eq(session.waiting_count(), 1)
            release.put(())
            assert_true(queued.wait() is SetKeyspace("node0"))
          }
          assert_true(owner.wait() is SetKeyspace("node0"))
          assert_eq(session.budget().in_flight, 0)
          assert_eq(session.budget().waiting, 0)
        })
      },
    )
  }
}

///|
async test "token replica wins locally while absent key or strategy safely uses round robin" {
  with_routing_fixture("dc1", (session, a, b) => {
    let hint = @client.RoutingHint::new("ks", b"\x00\x00\x00\x07")
    assert_eq(session.query_plan(hint~)[0].port, b)
    assert_true(
      session.query("select replica", routing=hint) is SetKeyspace("node1"),
    )
    assert_eq(session.query_plan()[0].port, a)
    assert_true(session.query("no partition key") is SetKeyspace("node0"))
    assert_true(
      session.query(
        "unsupported keyspace",
        routing=@client.RoutingHint::new("missing", hint.key),
      )
      is SetKeyspace("node1"),
    )
  })
}

///|
async test "local dc precedes remote replica and remote fallback requires explicit permission" {
  with_routing_fixture("dc1", remote_dc=true, (session, a, _) => {
    let hint = @client.RoutingHint::new("ks", b"\x00\x00\x00\x07")
    assert_eq(session.query_plan(hint~).length(), 1)
    assert_eq(session.query_plan(hint~)[0].port, a)
    assert_true(
      session.query("local non replica", routing=hint) is SetKeyspace("node0"),
    )
  })
  with_routing_fixture("absent", remote_dc=true, (session, _, _) => {
    assert_eq(session.query_plan().length(), 0)
    assert_true(
      try {
        ignore(
          session.query(
            "remote forbidden",
            deadline=@client.Deadline::after(100),
          ),
        )
        false
      } catch {
        @client.TimedOut(info) =>
          info.phase == WaitingConnection && !info.may_have_been_sent
        _ => false
      },
    )
  })
  with_routing_fixture("absent", remote_dc=true, allow_remote=true, (
    session,
    _,
    b,
  ) => {
    let hint = @client.RoutingHint::new("ks", b"\x00\x00\x00\x07")
    assert_eq(session.query_plan(hint~)[0].port, b)
    assert_true(
      session.query("remote permitted", routing=hint) is SetKeyspace("node1"),
    )
  })
}

///|
async test "expired metadata or unsupported partitioner loses token preference while retaining dc policy" {
  for unsupported in [false, true] {
    with_routing_fixture("dc1", expired=!unsupported, unsupported~, (
      session,
      a,
      _,
    ) => {
      @async.sleep(20)
      let hint = @client.RoutingHint::new("ks", b"\x00\x00\x00\x07")
      assert_eq(session.query_plan(hint~)[0].port, a)
      assert_true(
        session.query("safe fallback", routing=hint) is SetKeyspace("node0"),
      )
    })
  }
}

///|
async test "session prepared derives routing key from PREPARE partition indices" {
  with_routing_fixture("dc1", (session, _, _) => {
    let statement = session.prepare(
      "SELECT value FROM t WHERE arg=?",
      keyspace="ks",
    )
    guard statement.execute(
        [Integer(7)],
        options=@protocol.QueryOptions::new(skip_metadata=true),
      )
      is Rows(page) else {
      fail("missing routed prepared result")
    }
    assert_eq(page.rows[0][0], @types.Value::Integer(7))
  })
}
