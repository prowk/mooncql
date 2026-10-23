///|
fn changing_topology_row(
  index : Int,
  phase : Int,
  is_local : Bool,
) -> Bytes raise {
  if index == 0 {
    topology_rows(
      0,
      is_local,
      true,
      wide_tokens=true,
      identity=if phase >= 7 { 5 } else { 1 },
      token_values?=if phase >= 6 {
        Some(["4611686018427387904", "9223372036854775807"])
      } else {
        None
      },
      data_center=if phase == 5 { "dc3" } else { "dc1" },
    )
  } else {
    topology_rows(
      1,
      is_local,
      true,
      wide_tokens=true,
      address=if phase >= 1 { b"\x0a\x00\x00\x03" } else { b"\x0a\x00\x00\x02" },
      identity=if phase >= 2 { 9 } else { 2 },
      rack=if phase >= 4 { "changed-rack" } else { "rack1" },
      token_values?=if phase >= 6 {
        Some(["-4611686018427387904", "0"])
      } else {
        None
      },
      data_center=if phase == 4 || phase == 5 { "dc2" } else { "dc1" },
    )
  }
}

///|
async test "periodic topology snapshots isolate replacement identity address DC rack and RF changes" {
  @async.with_timeout(12000, () => {
    @async.with_task_group(group => {
      let servers = [
        @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0")),
        @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0")),
        @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0")),
      ]
      defer (for server in servers {
        server.close()
      })
      let phase = [0]
      let closed = [0, 0, 0]
      let accepted = [0, 0, 0]
      let block = [false]
      let refresh_entered : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let release_refresh : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let workers = []
      for physical in 0..<3 {
        workers.push(
          group.spawn(() => {
            @async.with_task_group(handlers => {
              while true {
                let next = Some(servers[physical].accept()) catch { _ => None }
                guard next is Some((tcp, _)) else { return }
                accepted[physical] += 1
                let serial = accepted[physical]
                ignore(
                  handlers.spawn(() => {
                    let peer = Peer::new(tcp)
                    defer {
                      peer.close()
                      closed[physical] += 1
                    }
                    handshake(peer)
                    let id = b"\{physical.to_byte()}\{serial.to_byte()}"
                    while true {
                      let next = Some(receive(peer)) catch { _ => None }
                      guard next is Some(request) else { return }
                      if request.header.opcode == 11 {
                        respond(peer, request.header.stream, 2, b"")
                      } else if request.header.opcode == 9 {
                        respond(
                          peer,
                          request.header.stream,
                          8,
                          session_metadata(id, b"metadata", "id"),
                        )
                      } else if request.header.opcode == 10 {
                        assert_eq(
                          @codec.Reader::new(request.body).short_bytes(),
                          id,
                        )
                        respond(peer, request.header.stream, 8, session_row(7))
                      } else {
                        let reader = @codec.Reader::new(request.body)
                        let cql = reader.long_string()
                        let body = if cql.contains("FROM system.local") {
                          if block[0] {
                            block[0] = false
                            refresh_entered.put(())
                            release_refresh.get()
                          }
                          changing_topology_row(
                            if physical == 0 {
                              0
                            } else {
                              1
                            },
                            phase[0],
                            true,
                          )
                        } else if cql.contains("FROM system.peers_v2") {
                          changing_topology_row(
                            if physical == 0 {
                              1
                            } else {
                              0
                            },
                            phase[0],
                            false,
                          )
                        } else if cql.contains("FROM system_schema.keyspaces") {
                          replication_rows(
                            simple=true,
                            factor=if phase[0] == 3 { 2 } else { 1 },
                          )
                        } else {
                          // 业务请求的 LOCAL_QUORUM 必须按原值传输。
                          assert_eq(reader.u16(), 6)
                          named_result("physical\{physical}")
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
          connection=@client.Config::new(heartbeat_interval_ms=0),
          contact_points=[@client.Endpoint::new(port=servers[0].addr.port())],
          connections_per_node=2,
          discovery=@client.DiscoveryConfig::new(
            refresh_interval_ms=100,
            debounce_ms=1,
            address_mapper=native => {
              let index = native.address[3].to_int() - 1
              Some(@client.Endpoint::new(port=servers[index].addr.port()))
            },
          ),
          routing=@client.RoutingConfig::new("dc1"),
        ),
        session => {
          ignore(wait_topology(session, 2, 1))
          wait_pool_ready(session, 2, 2)
          let hint = @client.RoutingHint::new("ks", b"\x00\x00\x00\x07")
          let options = @protocol.QueryOptions::new(consistency=LocalQuorum)
          assert_eq(session.query_plan(hint~)[0].port, servers[1].addr.port())
          let prepared = session.prepare(
            "SELECT id FROM ks.t WHERE arg=?",
            keyspace="ks",
          )
          assert_true(prepared.execute([Integer(7)]) is Rows(_))
          // 周期刷新在被阻塞时必须立刻撤销旧 token 偏好，而不是等失败后撤销。
          block[0] = true
          refresh_entered.get()
          assert_true(session.control_status().unwrap().stale)
          assert_eq(session.query_plan(hint~)[0].port, servers[0].addr.port())
          assert_true(
            session.query("stale fallback", options~)
            is SetKeyspace("physical0"),
          )
          release_refresh.put(())
          let revision = session.topology().unwrap().revision
          ignore(wait_topology(session, 2, revision + 1))
          // 不发送事件：地址变化由周期快照收敛，整个旧节点池结束。
          phase[0] = 1
          let revision = session.topology().unwrap().revision
          ignore(wait_topology(session, 2, revision + 1))
          wait_pool_ready(session, 2, 2)
          while closed[1] != 2 {
            @async.sleep(1)
          }
          assert_true(
            !session
            .nodes()
            .any(node => node.endpoint.port == servers[1].addr.port()),
          )
          assert_eq(session.query_plan(hint~)[0].port, servers[2].addr.port())
          assert_true(prepared.execute([Integer(7)]) is Rows(_))
          let connections_before = accepted[2]
          assert_eq(connections_before, 2)
          // 地址未变而 host_id 改变也必须结束旧池，不能保留旧 PREPARE ID。
          phase[0] = 2
          let revision = session.topology().unwrap().revision
          let replaced = wait_topology(session, 2, revision + 1)
          wait_pool_ready(session, 2, 2)
          while closed[2] != connections_before {
            @async.sleep(1)
          }
          assert_eq(accepted[2], 4)
          assert_eq(replaced.nodes[1].host_id[15], b'\x09')
          assert_true(prepared.execute([Integer(7)]) is Rows(_))
          // 复制因子调整后两节点均为副本，轮转起点取代旧的单副本偏好。
          phase[0] = 3
          let revision = session.topology().unwrap().revision
          ignore(wait_topology(session, 2, revision + 1))
          assert_true(
            session.topology().unwrap().keyspaces.get("ks")
            is Some(@routing.Replication::Simple(2)),
          )
          assert_eq(session.query_plan(hint~)[0].port, servers[0].addr.port())
          phase[0] = 4
          let revision = session.topology().unwrap().revision
          let moved = wait_topology(session, 2, revision + 1)
          assert_eq(moved.nodes[1].rack, "changed-rack")
          assert_eq(moved.nodes[1].data_center, "dc2")
          assert_eq(session.query_plan(hint~).length(), 1)
          assert_true(
            session.query("local DC preserved", options~, routing=hint)
            is SetKeyspace("physical0"),
          )
          phase[0] = 5
          let revision = session.topology().unwrap().revision
          ignore(wait_topology(session, 2, revision + 1))
          assert_eq(session.query_plan(hint~).length(), 0)
          assert_true(
            try {
              ignore(
                session.query(
                  "no local DC",
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
          phase[0] = 6
          let revision = session.topology().unwrap().revision
          let retokened = wait_topology(session, 2, revision + 1)
          assert_eq(retokened.nodes[0].tokens[0], 4611686018427387904L)
          assert_eq(session.query_plan(hint~)[0].port, servers[0].addr.port())
          assert_eq(accepted[2], 4)
          assert_eq(closed[2], 2)
          phase[0] = 7
          let revision = session.topology().unwrap().revision
          let control_generation = session.control_status().unwrap().generation
          let observer_replaced = wait_topology(session, 2, revision + 1)
          wait_pool_ready(session, 2, 2)
          assert_eq(
            observer_replaced.nodes.filter(node => {
              node.native.address == b"\x0a\x00\x00\x01"
            })[0].host_id[15],
            b'\x05',
          )
          assert_true(
            session.control_status().unwrap().generation > control_generation,
          )
          while closed[0] < 3 {
            @async.sleep(1)
          }
          assert_true(prepared.execute([Integer(7)]) is Rows(_))
          session.close()
          assert_eq(session.resources().background_task_handles, 0)
          assert_eq(session.budget().in_flight_bytes, 0L)
          assert_eq(session.budget().waiting, 0)
        },
      )
    })
  })
}
