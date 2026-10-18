///|
fn topology_rows(
  index : Int,
  is_local : Bool,
  included : Bool,
  invalid? : Bool = false,
) -> Bytes raise {
  let w = @codec.Writer::new()
  w.i32(2)
  w.i32(1)
  w.i32(if is_local { 9 } else { 7 })
  w.string("system")
  w.string(if is_local { "local" } else { "peers_v2" })
  let columns = [
    ("host_id", 12),
    (if is_local { "rpc_address" } else { "native_address" }, 16),
    (if is_local { "rpc_port" } else { "native_port" }, 9),
    ("data_center", 13),
    ("rack", 13),
    ("tokens", 34),
    ("schema_version", 12),
  ]
  for pair in columns {
    let (name, code) = pair
    w.string(name)
    w.u16(code)
    if code == 34 {
      w.u16(13)
    }
  }
  if is_local {
    w.string("partitioner")
    w.u16(13)
    w.string("cluster_name")
    w.u16(13)
  }
  w.i32(if included { 1 } else { 0 })
  if included {
    let id = Bytes::from_array(
      Array::makei(16, i => {
        if i == 15 {
          (index + 1).to_byte()
        } else {
          b'\x00'
        }
      }),
    )
    let values : Array[@types.Value] = [
      Uuid(id),
      Inet(if index == 0 { b"\x0a\x00\x00\x01" } else { b"\x0a\x00\x00\x02" }),
      Integer(9042),
      Text("dc1"),
      Text("rack\{index}"),
      if invalid {
        Null
      } else {
        SetValue(
          if index == 0 {
            [Text("-10"), Text("0")]
          } else {
            [Text("10"), Text("20")]
          },
        )
      },
      Uuid(b"schema-version01"),
    ]
    if is_local {
      values.push(Text("org.apache.cassandra.dht.Murmur3Partitioner"))
      values.push(Text("test-cluster"))
    }
    for value in values {
      @types.write_value(w, value)
    }
  }
  w.to_bytes()
}

///|
async fn wait_topology(
  session : @client.Session,
  count : Int,
  revision : Int,
) -> @client.TopologySnapshot {
  @async.with_timeout(5000, () => {
    while true {
      if session.topology() is Some(snapshot) &&
        snapshot.nodes.length() == count &&
        snapshot.revision >= revision {
        return snapshot
      }
      @async.sleep(5)
    } nobreak {
      fail("topology wait ended")
    }
  })
}

///|
async test "control snapshot converges across burst missing events removal mapped endpoints and resubscription" {
  @async.with_timeout(15000, () => {
    @async.with_task_group(group => {
      let servers = [
        @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0")),
        @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0")),
      ]
      defer (for server in servers {
        server.close()
      })
      let phase = [0]
      let registrations = [0]
      let controls : @async.Queue[Peer] = @async.Queue(kind=Blocking(4))
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
                    defer peer.close()
                    handshake(peer)
                    let mut is_control = false
                    while true {
                      let request = Some(receive(peer)) catch { _ => None }
                      guard request is Some(request) else { return }
                      if request.header.opcode == 11 {
                        is_control = true
                        registrations[0] += 1
                        controls.put(peer)
                        respond(peer, request.header.stream, 2, b"")
                      } else {
                        if phase[0] == 4 && index == 0 && is_control {
                          return
                        }
                        let cql = @codec.Reader::new(request.body).long_string()
                        let body = if cql.contains("FROM system.local") {
                          topology_rows(index, true, true)
                        } else if cql.contains("FROM system.peers_v2") {
                          topology_rows(
                            1 - index,
                            false,
                            phase[0] != 1,
                            invalid=phase[0] == 3,
                          )
                        } else {
                          b"\x00\x00\x00\x01"
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
          connection=@client.Config::new(event_capacity=4),
          contact_points=[@client.Endpoint::new(port=servers[0].addr.port())],
          discovery=@client.DiscoveryConfig::new(
            refresh_interval_ms=300,
            debounce_ms=60,
            address_mapper=native => {
              if native.port != 9042 {
                None
              } else if native.address == b"\x0a\x00\x00\x01" {
                Some(@client.Endpoint::new(port=servers[0].addr.port()))
              } else if native.address == b"\x0a\x00\x00\x02" {
                Some(@client.Endpoint::new(port=servers[1].addr.port()))
              } else {
                None
              }
            },
          ),
        ),
        session => {
          let control = controls.get()
          let initial = wait_topology(session, 2, 1)
          wait_session_nodes(session, 2)
          assert_eq(initial.cluster_name, "test-cluster")
          assert_eq(
            initial.partitioner,
            "org.apache.cassandra.dht.Murmur3Partitioner",
          )
          assert_eq(
            initial.nodes[0].host_id,
            b"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01",
          )
          assert_eq(initial.nodes[0].tokens, [-10L, 0L])
          assert_eq(initial.nodes[1].tokens, [10L, 20L])
          assert_eq(initial.nodes[1].data_center, "dc1")
          assert_eq(initial.nodes[1].rack, "rack1")
          // 修改公开快照不能污染控制任务内部的元数据。
          initial.nodes[0].tokens[0] = 999L
          guard session.topology() is Some(copy) else {
            fail("missing snapshot")
          }
          assert_eq(copy.nodes[0].tokens[0], -10L)
          let before = session.control_status().unwrap().refreshes
          phase[0] = 1
          for _ in 0..<1000 {
            respond(control, -1, 12, status_event(false))
          }
          let removed = wait_topology(session, 1, initial.revision + 1)
          assert_eq(session.nodes().length(), 1)
          assert_true(session.control_status().unwrap().refreshes - before < 20)
          // 故意遗漏新增通知，周期快照仍应恢复成员。
          phase[0] = 2
          let restored = wait_topology(session, 2, removed.revision + 1)
          wait_session_nodes(session, 2)
          assert_true(
            restored.nodes.any(node => {
              node.native.address == b"\x0a\x00\x00\x02"
            }),
          )
          phase[0] = 4
          ignore(controls.get())
          @async.with_timeout(5000, () => {
            while session.control_status().unwrap().generation < 2 ||
                  session.control_status().unwrap().stale {
              @async.sleep(5)
            }
          })
          assert_true(registrations[0] >= 2)
          assert_true(
            session.query("business after control replacement") is Void,
          )
          let good = session.topology().unwrap()
          phase[0] = 3
          @async.with_timeout(5000, () => {
            while session.control_status().unwrap().last_error is None {
              @async.sleep(5)
            }
          })
          assert_true(session.control_status().unwrap().stale)
          assert_eq(session.topology().unwrap().revision, good.revision)
          assert_eq(session.nodes().length(), 2)
          assert_true(
            session.query("business while invalid metadata is rejected") is Void,
          )
          phase[0] = 2
          ignore(wait_topology(session, 2, good.revision + 1))
          session.close()
          assert_true(!session.control_status().unwrap().connected)
          assert_true(session.nodes().all(node => node.status.state == Stopped))
          assert_eq(session.active_count(), 0)
          assert_eq(session.waiting_count(), 0)
        },
      )
      for worker in workers {
        worker.cancel()
      }
      for worker in workers {
        ignore(worker.wait()) catch {
          _ => ()
        }
      }
    })
  })
}
