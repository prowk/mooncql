///|
async test "idle heartbeats share total credit skip busy Session and release reservation during draining" {
  @async.with_timeout(6000, () => {
    @async.with_task_group(group => {
      let servers = [
        @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0")),
        @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0")),
      ]
      defer (for server in servers {
        server.close()
      })
      let business_seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let business_release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let heartbeat_seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let heartbeat_release : @async.Queue[Unit] = @async.Queue(
        kind=Blocking(1),
      )
      let hold_heartbeat = [false]
      let heartbeats = [0]
      let workers = []
      for index in 0..<2 {
        workers.push(
          group.spawn(() => {
            let (tcp, _) = servers[index].accept()
            let peer = Peer::new(tcp)
            defer peer.close()
            handshake(peer)
            while true {
              let request = Some(receive(peer)) catch { _ => None }
              guard request is Some(request) else { return }
              if request.header.opcode == 5 {
                heartbeats[0] += 1
                if hold_heartbeat[0] {
                  hold_heartbeat[0] = false
                  heartbeat_seen.put(())
                  heartbeat_release.get()
                }
                respond(peer, request.header.stream, 6, heartbeat_supported())
              } else {
                assert_eq(
                  @codec.Reader::new(request.body).long_string(),
                  "held",
                )
                business_seen.put(())
                business_release.get()
                respond(peer, request.header.stream, 8, b"\x00\x00\x00\x01")
              }
            }
          }),
        )
      }
      @client.with_session(
        config=@client.SessionConfig::new(
          connection=@client.Config::new(
            heartbeat_interval_ms=20,
            heartbeat_timeout_ms=2000,
          ),
          contact_points=servers.map(server => {
            @client.Endpoint::new(port=server.addr.port())
          }),
          limits=@client.SessionLimits::new(max_in_flight=1),
        ),
        session => {
          wait_session_nodes(session, 2)
          @async.with_task_group(requests => {
            let business = requests.spawn(() => session.query("held"))
            business_seen.get()
            let before = heartbeats[0]
            @async.sleep(80)
            assert_eq(heartbeats[0], before)
            assert_eq(session.budget().in_flight, 1)
            assert_true(session.nodes().all(node => node.status.state == Ready))
            hold_heartbeat[0] = true
            business_release.put(())
            assert_true(business.wait() is Void)
            heartbeat_seen.get()
            // 此时没有逻辑操作，仍有一个实际心跳 RPC 占用总额度。
            assert_eq(session.active_count(), 0)
            assert_eq(session.budget().in_flight, 1)
            assert_eq(session.budget().in_flight_bytes, 9L)
            let queued = requests.spawn(() => session.query("must not send"))
            while session.budget().waiting == 0 {
              @async.pause()
            }
            queued.cancel()
            ignore(queued.wait()) catch {
              _ => ()
            }
            assert_eq(session.budget().waiting, 0)
            heartbeat_release.put(())
            // 确认响应已被消费，避免测试服务端向排空时已关闭的连接写入。
            while session.budget().in_flight > 0 {
              @async.pause()
            }
          })
          assert_eq(
            session.drain(@client.Deadline::after(2000)),
            @client.DrainOutcome::Drained,
          )
          assert_eq(session.budget().in_flight, 0)
          assert_eq(session.budget().in_flight_bytes, 0L)
          assert_eq(session.resources().background_task_handles, 0)
        },
      )
      for worker in workers {
        worker.wait()
      }
    })
  })
}

///|
async test "control catalog RPC and coalesced schema readers use the same Session budget as business queries" {
  @async.with_timeout(7000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let control_seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let control_release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let version_seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let version_release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let control_hold = [true]
      let version_hold = [true]
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
                    continue
                  }
                  let cql = @codec.Reader::new(request.body).long_string()
                  let body = if cql.contains("SELECT schema_version FROM") {
                    if version_hold[0] {
                      version_hold[0] = false
                      version_seen.put(())
                      version_release.get()
                    }
                    schema_version_result(Some(b"aaaaaaaaaaaaaaaa"))
                  } else if cql.contains("FROM system.local") {
                    if control_hold[0] {
                      control_hold[0] = false
                      control_seen.put(())
                      control_release.get()
                    }
                    topology_rows(0, true, true)
                  } else if cql.contains("FROM system.peers_v2") {
                    topology_rows(1, false, false)
                  } else if cql.contains("system_schema.keyspaces") &&
                    !cql.contains("durable_writes") {
                    replication_rows()
                  } else if cql == "business" {
                    b"\x00\x00\x00\x01"
                  } else {
                    catalogs[0] += 1
                    schema_fixture(cql)
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
      @client.with_session(
        config=@client.SessionConfig::new(
          connection=@client.Config::new(
            port=server.addr.port(),
            heartbeat_interval_ms=0,
          ),
          limits=@client.SessionLimits::new(max_in_flight=1, max_waiting=1),
          discovery=@client.DiscoveryConfig::new(refresh_interval_ms=60000, address_mapper=_ => {
            Some(@client.Endpoint::new(port=server.addr.port()))
          }),
        ),
        session => {
          control_seen.get()
          assert_eq(session.budget().in_flight, 1)
          @async.with_task_group(requests => {
            let business = requests.spawn(() => session.query("business"))
            while session.budget().waiting == 0 {
              @async.pause()
            }
            assert_eq(session.budget().waiting, 1)
            assert_eq(session.budget().in_flight, 1)
            control_release.put(())
            assert_true(business.wait() is Void)
            ignore(wait_topology(session, 1, 1))
            wait_session_nodes(session, 1)
            let options = @client.SchemaOptions::new(keyspaces=["ks"])
            let owner = requests.spawn(() => session.schema_metadata(options~))
            version_seen.get()
            assert_eq(session.budget().in_flight, 1)
            let follower = requests.spawn(() => {
              session.schema_metadata(options~)
            })
            while session.budget().waiting == 0 {
              @async.pause()
            }
            assert_eq(session.budget().waiting, 1)
            version_release.put(())
            assert_true(owner.wait().table("ks", "events") is Some(_))
            assert_true(follower.wait().table("ks", "events") is Some(_))
            assert_eq(catalogs[0], 5)
            assert_eq(session.budget().in_flight, 0)
            assert_eq(session.budget().waiting, 0)
          })
          session.close()
          assert_eq(session.budget().in_flight_bytes, 0L)
          assert_eq(session.budget().waiting_bytes, 0L)
        },
      )
    })
  })
}
