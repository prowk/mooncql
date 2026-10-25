///|
fn commitment_write(
  kind : Int,
  large? : Bool = false,
) -> @protocol.Request raise {
  let values : Array[@types.Value] = if large {
    [Bytes(Bytes::make(32000000, b'x'))]
  } else {
    [Integer(7)]
  }
  let cql = "INSERT INTO ks.events(id) VALUES(?)"
  if kind == 0 {
    @protocol.query(cql, values~)
  } else {
    @protocol.batch(
      [Query(cql, values)],
      kind=match kind {
        1 => Logged
        2 => Unlogged
        _ => Counter
      },
    )
  }
}

///|
async test "commitment concurrent QUERY and three BATCH kinds correlate reversed success and error responses" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let requests = []
        for _ in 0..<16 {
          requests.push(receive(peer))
        }
        for index = 15; index >= 0; index = index - 1 {
          let request = requests[index]
          let reader = @codec.Reader::new(request.body)
          if request.header.opcode == 13 {
            ignore(reader.u8())
            assert_eq(reader.u16(), 1)
            assert_eq(reader.u8(), 0)
          }
          let id = reader.long_string()
          if request.header.opcode == 7 {
            respond(peer, request.header.stream, 8, named_result(id))
          } else {
            let error = @codec.Writer::new()
            error.i32(0x2200)
            error.string(id)
            respond(peer, request.header.stream, 0, error.to_bytes())
          }
        }
        assert_eq(peer.read_some(), None)
      })
      @client.with_connection_builder(
        config=@client.ConnectionBuilder::new(port=server.addr.port()),
        connection => {
          let actions : Array[async () -> Unit] = Array::makei(16, id => {
            () => {
              if id % 4 == 0 {
                assert_true(
                  connection.query(id.to_string()) is SetKeyspace(name) &&
                  name == id.to_string(),
                )
              } else {
                assert_true(
                  try {
                    connection.batch(
                      [Query(id.to_string(), [])],
                      kind=match id % 4 {
                        1 => Logged
                        2 => Unlogged
                        _ => Counter
                      },
                    )
                    false
                  } catch {
                    @client.Server(error) =>
                      error.code == 0x2200 && error.message == id.to_string()
                    _ => false
                  },
                )
              }
            }
          })
          ignore(@async.all(actions))
          assert_eq(connection.pending_count(), 0)
          assert_eq(connection.in_flight_bytes(), 0L)
        },
      )
      worker.wait()
    })
  })
}

///|
async test "commitment QUERY and three BATCH kinds isolate unsent cancelled late and server-error writes" {
  for kind in 0..<4 {
    @async.with_timeout(5000, () => {
      let write = commitment_write(kind)
      @async.with_task_group(group => {
        let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
        let release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
        let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
        defer server.close()
        let worker = group.spawn(() => {
          let (tcp, _) = server.accept()
          let peer = Peer::new(tcp)
          defer peer.close()
          handshake(peer)
          let blocker = receive(peer)
          seen.put(())
          release.get()
          respond(peer, blocker.header.stream, 8, named_result("blocker"))
          // 排队取消的写入不得到达服务端；下一条是调用方的标记。
          let marker = receive(peer)
          assert_eq(@codec.Reader::new(marker.body).long_string(), "marker")
          respond(peer, marker.header.stream, 8, named_result("marker"))
          let cancelled = receive(peer)
          assert_eq(cancelled.header.opcode, write.opcode)
          assert_eq(cancelled.body, write.body)
          seen.put(())
          release.get()
          respond(peer, cancelled.header.stream, 8, b"\x00\x00\x00\x01")
          let failed = receive(peer)
          assert_eq(failed.header.opcode, write.opcode)
          assert_eq(failed.body, write.body)
          respond(peer, failed.header.stream, 0, overload_error())
          // 可重试的服务端错误也不能使低层写入自动再次发送。
          let marker = receive(peer)
          assert_eq(
            @codec.Reader::new(marker.body).long_string(),
            "after error",
          )
          respond(peer, marker.header.stream, 8, named_result("after error"))
          assert_eq(peer.read_some(), None)
        })
        let closed = @client.with_connection_builder(
          config=@client.ConnectionBuilder::new(
            port=server.addr.port(),
            max_in_flight=1,
          ),
          connection => {
            @async.with_task_group(requests => {
              let blocker = requests.spawn(() => connection.query("blocker"))
              seen.get()
              let cancelled = requests.spawn(() => connection.run(write))
              while connection.waiting_count() != 1 {
                @async.pause()
              }
              cancelled.cancel()
              ignore(cancelled.wait()) catch {
                _ => ()
              }
              assert_eq(connection.waiting_count(), 0)
              assert_eq(connection.waiting_bytes(), 0L)
              release.put(())
              assert_true(blocker.wait() is SetKeyspace("blocker"))
              assert_true(connection.query("marker") is SetKeyspace("marker"))
              let cancelled = requests.spawn(() => connection.run(write))
              seen.get()
              cancelled.cancel()
              ignore(cancelled.wait()) catch {
                _ => ()
              }
              assert_eq(connection.abandoned_count(), 1)
              release.put(())
              assert_true(
                try {
                  ignore(connection.run(write))
                  false
                } catch {
                  @client.Server(error) => error.code == 0x1001
                  _ => false
                },
              )
              assert_true(
                connection.query("after error") is SetKeyspace("after error"),
              )
              assert_eq(connection.abandoned_count(), 0)
              assert_eq(connection.pending_count(), 0)
              assert_eq(connection.in_flight_bytes(), 0L)
            })
            connection
          },
        )
        assert_true(closed.is_closed())
        worker.wait()
      })
    })
  }
}

///|
async test "commitment partial QUERY and BATCH send cancellation or EOF closes without replay" {
  for kind in 0..<4 {
    for cancel in [true, false] {
      @async.with_timeout(15000, () => {
        @async.with_task_group(group => {
          let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
          let release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
          let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
          defer server.close()
          let worker = group.spawn(() => {
            let (tcp, _) = server.accept()
            let peer = Peer::new(tcp)
            defer peer.close()
            handshake(peer)
            // 只读取外层帧头，不接收完整正文，使发送阶段确定性阻塞。
            ignore(tcp.read_exactly(6))
            seen.put(())
            release.get()
            if cancel {
              try {
                while tcp.read_some() is Some(_) {
                  ()
                }
              } catch {
                @os_error.OSError(_, ..) => ()
                error => raise error
              }
            }
          })
          @client.with_connection_builder(
            config=@client.ConnectionBuilder::new(
              port=server.addr.port(),
              max_frame_bytes=40000000,
            ),
            connection => {
              @async.with_task_group(requests => {
                let task = requests.spawn(() => {
                  Ok(connection.run(commitment_write(kind, large=true))) catch {
                    error => Err(error)
                  }
                })
                seen.get()
                if cancel {
                  task.cancel()
                  ignore(task.wait()) catch {
                    _ => ()
                  }
                  release.put(())
                } else {
                  release.put(())
                  assert_true(task.wait() is Err(_))
                }
                assert_true(connection.is_closed())
                assert_eq(connection.pending_count(), 0)
                assert_eq(connection.abandoned_count(), 0)
                assert_eq(connection.in_flight_bytes(), 0L)
                assert_eq(connection.waiting_bytes(), 0L)
              })
            },
          )
          worker.wait()
        })
      })
    }
  }
}

///|
async test "commitment mismatched UNPREPARED and prepared BATCH never trigger recovery" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let prepared = receive(peer)
        respond(peer, prepared.header.stream, 8, prepared_result(b"actual"))
        for opcode in [10, 13] {
          let write = receive(peer)
          assert_eq(write.header.opcode, opcode)
          let error = @codec.Writer::new()
          error.i32(0x2500)
          error.string("missing")
          error.short_bytes(if opcode == 10 { b"another" } else { b"actual" })
          respond(peer, write.header.stream, 0, error.to_bytes())
        }
        let marker = receive(peer)
        assert_eq(
          @codec.Reader::new(marker.body).long_string(),
          "after unprepared",
        )
        respond(peer, marker.header.stream, 8, b"\x00\x00\x00\x01")
        assert_eq(peer.read_some(), None)
      })
      @client.with_connection_builder(
        config=@client.ConnectionBuilder::new(port=server.addr.port()),
        connection => {
          let prepared = connection.prepare("INSERT INTO ks.t(id) VALUES(?)")
          assert_true(
            try {
              ignore(prepared.execute([Integer(7)]))
              false
            } catch {
              @client.Server(error) =>
                error.detail is Unprepared(id) && id == b"another"
              _ => false
            },
          )
          assert_true(
            try {
              connection.batch([prepared.bind_batch([Integer(7)])])
              false
            } catch {
              @client.Server(error) =>
                error.detail is Unprepared(id) && id == b"actual"
              _ => false
            },
          )
          assert_true(connection.query("after unprepared") is Void)
        },
      )
      worker.wait()
    })
  })
}
