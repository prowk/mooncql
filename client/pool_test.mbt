///|
async fn wait_pool_ready(
  session : @client.Session,
  nodes : Int,
  size : Int,
) -> Unit {
  while session.pools().length() != nodes ||
        !session.pools().all(pool => pool.ready == size) {
    @async.pause()
  }
}

///|
fn pool_batch(id : Bytes, kind : @protocol.BatchType) -> Bytes raise {
  @protocol.batch(
    [Query("plain", [Integer(1)]), Prepared(id, [Integer(7)])],
    kind~,
    options=@protocol.QueryOptions::new(keyspace="fixed_keyspace"),
  ).body
}

///|
async test "pool slots keep prepared IDs result metadata and preparation locks isolated and batch uses one physical coordinator" {
  @async.with_timeout(7000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let second_prepare : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let release_prepare : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let primary = [-1]
      let prepares = [0]
      let batches : Array[Array[@protocol.BatchType]] = [[], []]
      let worker = group.spawn(() => {
        @async.with_task_group(handlers => {
          for index in 0..<2 {
            let (tcp, _) = server.accept()
            ignore(
              handlers.spawn(() => {
                let peer = Peer::new(tcp)
                defer peer.close()
                handshake(peer)
                let id = if index == 0 { b"a" } else { b"b" }
                let metadata = if index == 0 { b"meta-a" } else { b"meta-b" }
                let newer = if index == 0 {
                  b"meta-a-new"
                } else {
                  b"meta-b-new"
                }
                let column = if index == 0 { "column-a" } else { "column-b" }
                let mut changed = false
                let mut executions = 0
                while true {
                  let request = Some(receive(peer)) catch { _ => None }
                  guard request is Some(request) else { return }
                  match request.header.opcode {
                    9 => {
                      assert_session_prepare(request)
                      prepares[0] += 1
                      if prepares[0] == 1 {
                        primary[0] = index
                      } else {
                        assert_eq(prepares[0], 2)
                        second_prepare.put(())
                        release_prepare.get()
                      }
                      respond(
                        peer,
                        request.header.stream,
                        8,
                        session_metadata(id, metadata, column),
                      )
                    }
                    10 => {
                      let value = if primary[0] == index {
                        if executions == 0 {
                          2
                        } else {
                          4
                        }
                      } else if executions == 0 {
                        3
                      } else {
                        5
                      }
                      assert_session_execute(
                        request,
                        id,
                        if changed {
                          newer
                        } else {
                          metadata
                        },
                        value,
                      )
                      executions += 1
                      if primary[0] == index && !changed {
                        changed = true
                        respond(
                          peer,
                          request.header.stream,
                          8,
                          changed_session_row(column + "-new", newer, value),
                        )
                      } else {
                        respond(
                          peer,
                          request.header.stream,
                          8,
                          session_row(value),
                        )
                      }
                    }
                    13 => {
                      let kind = if primary[0] == index {
                        @protocol.BatchType::Unlogged
                      } else if batches[index].is_empty() {
                        Logged
                      } else {
                        Counter
                      }
                      assert_eq(request.body, pool_batch(id, kind))
                      batches[index].push(kind)
                      respond(
                        peer,
                        request.header.stream,
                        8,
                        b"\x00\x00\x00\x01",
                      )
                    }
                    _ => fail("unexpected pooled request")
                  }
                }
              }),
            )
          }
        })
      })
      @client.with_session_builder(
        config=@client.SessionBuilder::new(
          connection=@client.ConnectionBuilder::new(
            port=server.addr.port(),
            heartbeat_interval_ms=0,
          ),
          connections_per_node=2,
        ),
        session => {
          wait_pool_ready(session, 1, 2)
          let statement = session.prepare(
            "SELECT value FROM t WHERE arg=?",
            keyspace="fixed_keyspace",
          )
          let primary_column = if primary[0] == 0 {
            "column-a"
          } else {
            "column-b"
          }
          let secondary_column = if primary[0] == 0 {
            "column-b"
          } else {
            "column-a"
          }
          let options = @protocol.QueryOptions::new(skip_metadata=true)
          @async.with_task_group(requests => {
            let secondary = requests.spawn(() => {
              statement.execute([Integer(3)], options~)
            })
            second_prepare.get()
            // 第二槽的准备仍阻塞时，第一槽必须能够独立执行并更新自己的结果元数据。
            guard statement.execute([Integer(2)], options~) is Rows(first) else {
              fail("missing first slot result")
            }
            assert_eq(
              first.get(0, primary_column + "-new"),
              @types.Value::Integer(2),
            )
            release_prepare.put(())
            guard secondary.wait() is Rows(second) else {
              fail("missing second slot result")
            }
            assert_eq(second.get(0, secondary_column), @types.Value::Integer(3))
          })
          guard statement.execute([Integer(5)], options~) is Rows(second) else {
            fail("missing cached second slot")
          }
          assert_eq(second.get(0, secondary_column), @types.Value::Integer(5))
          guard statement.execute([Integer(4)], options~) is Rows(first) else {
            fail("missing cached first slot")
          }
          assert_eq(
            first.get(0, primary_column + "-new"),
            @types.Value::Integer(4),
          )
          let batch = [
            @client.SessionBatchStatement::query("plain", values=[Integer(1)]),
            statement.bind_batch([Integer(7)]),
          ]
          for kind in [@protocol.BatchType::Logged, Unlogged, Counter] {
            session.batch(
              batch,
              kind~,
              options=@protocol.QueryOptions::new(keyspace="fixed_keyspace"),
            )
          }
          assert_eq(prepares[0], 2)
          assert_true(batches[primary[0]] is [@protocol.BatchType::Unlogged])
          assert_true(
            batches[1 - primary[0]] is [@protocol.BatchType::Logged, Counter],
          )
          let exposed = session.pools()
          exposed[0].connections.clear()
          assert_eq(session.pools()[0].connections.length(), 2)
          assert_eq(session.resources().cache_sizes, [1, 1])
          session.close()
          assert_eq(session.budget().in_flight, 0)
          assert_eq(session.budget().waiting, 0)
          assert_eq(session.resources().background_task_handles, 0)
        },
      )
      worker.wait()
    })
  })
}

///|
async test "invalid per-node pool sizes fail before any network operation" {
  for size in [0, 9, -1] {
    assert_true(
      try {
        @client.with_session_builder(
          config=@client.SessionBuilder::new(
            connection=@client.ConnectionBuilder::new(port=1),
            connections_per_node=size,
          ),
          _ => (),
        )
        false
      } catch {
        @client.Configuration(_) => true
        _ => false
      },
    )
  }
}
