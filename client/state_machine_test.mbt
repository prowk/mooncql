///|
fn model_random(state : Array[UInt32], bound : Int32) -> Int32 {
  state[0] = state[0] * 1664525U + 1013904223U
  ((state[0] >> 1) % bound.reinterpret_as_uint()).reinterpret_as_int()
}

///|
async test "fixed seed multiplex model combines reordered TCP fragments cancellation and partial EOF" {
  @async.with_timeout(20000, () => {
    let seed = @string.parse_uint(
      @env.get_env_var("CQL_TEST_SEED").unwrap_or("2026101819"),
    )
    let rounds = @string.parse_int(
      @env.get_env_var("CQL_TEST_ROUNDS").unwrap_or("32"),
    )
    assert_true(rounds >= 1 && rounds <= 256)
    let only = @string.parse_int(
      @env.get_env_var("CQL_TEST_CASE").unwrap_or("-1"),
    )
    let width = @string.parse_int(
      @env.get_env_var("CQL_TEST_WIDTH").unwrap_or("12"),
    )
    let cancels = @string.parse_int(
      @env.get_env_var("CQL_TEST_CANCELS").unwrap_or("4"),
    )
    let fragment = @string.parse_int(
      @env.get_env_var("CQL_TEST_FRAGMENT").unwrap_or("31"),
    )
    assert_true(
      only >= -1 &&
      only < rounds &&
      width >= 1 &&
      width <= 12 &&
      cancels >= 0 &&
      cancels <= 12 &&
      fragment >= 1 &&
      fragment <= 131071,
    )
    for round in 0..<rounds {
      if only >= 0 && round != only {
        continue
      }
      // 各轮独立派生种子，可直接重放单轮，缩减时不依赖此前网络分片数量。
      let random = [seed ^ ((round + 1).reinterpret_as_uint() * 2654435761U)]
      errdefer println(
        "replay CQL_TEST_SEED=\{seed} CQL_TEST_ROUNDS=\{round + 1} CQL_TEST_CASE=\{round} CQL_TEST_WIDTH=\{width} CQL_TEST_CANCELS=\{cancels} CQL_TEST_FRAGMENT=\{fragment}; phase=multiplex round=\{round}",
      )
      let compressed = round % 2 == 0
      let order = Array::makei(width, index => index)
      for index in 0..<width {
        let other = model_random(random, width)
        let saved = order[index]
        order[index] = order[other]
        order[other] = saved
      }
      let cancelled = Array::make(width, false)
      for _ in 0..<cancels {
        cancelled[model_random(random, width)] = true
      }
      let eof = round % 3 == 0
      let completed = if eof { model_random(random, width) } else { width }
      let replied = Array::make(width, false)
      for index in 0..<completed {
        replied[order[index]] = true
      }
      let metrics = @client.Metrics::new()
      @async.with_task_group(group => {
        let ready : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
        let release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
        let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
        defer server.close()
        let worker = group.spawn(() => {
          let (tcp, _) = server.accept()
          let peer = Peer::new(tcp, compressed~)
          defer peer.close()
          handshake(peer)
          let streams = Array::make(width, -1)
          for _ in 0..<width {
            let message = receive(peer)
            let id = @string.parse_int(
              @codec.Reader::new(message.body).long_string(),
            )
            assert_true(id >= 0 && id < width && streams[id] == -1)
            streams[id] = message.header.stream
          }
          ready.put(())
          release.get()
          let output = @codec.Writer::new()
          for index in 0..<(completed + (if eof { 1 } else { 0 })) {
            let id = order[index]
            let envelope = @protocol.encode_envelope(
              streams[id],
              8,
              rows_result([id], None),
              response=true,
            )
            let frames = @framing.split(envelope, compressed~)
            assert_eq(frames.length(), 1)
            output.raw(
              if index == completed {
                frames[0][:3].to_owned()
              } else {
                frames[0]
              },
            )
          }
          let bytes = output.to_bytes()
          let mut position = 0
          while position < bytes.length() {
            let width = 1 + model_random(random, fragment)
            let remaining = bytes.length() - position
            let end = position +
              (if width < remaining { width } else { remaining })
            peer.write(bytes[position:end].to_owned())
            position = end
          }
          if !eof {
            assert_eq(peer.read_some(), None)
          }
        })
        @client.with_connection_builder(
          config=@client.ConnectionBuilder::new(
            port=server.addr.port(),
            compression=compressed,
            max_in_flight=width,
            metrics~,
          ),
          connection => {
            @async.with_task_group(requests => {
              let tasks = []
              for id in 0..<width {
                tasks.push(
                  requests.spawn(() => {
                    try {
                      guard connection.query(id.to_string()) is Rows(page) else {
                        fail("missing model row")
                      }
                      Ok(page.row(0).int("id"))
                    } catch {
                      error => Err(error)
                    }
                  }),
                )
              }
              ready.get()
              assert_eq(connection.pending_count(), width)
              let mut cancelled_count = 0
              for id in 0..<width {
                if cancelled[id] {
                  tasks[id].cancel()
                  ignore(tasks[id].wait()) catch {
                    _ => ()
                  }
                  cancelled_count += 1
                }
              }
              assert_eq(connection.abandoned_count(), cancelled_count)
              assert_eq(connection.in_flight_count(), width)
              release.put(())
              for id in 0..<width {
                if !cancelled[id] {
                  match tasks[id].wait() {
                    Ok(value) => {
                      assert_true(replied[id])
                      assert_eq(value, id)
                    }
                    Err(_) => assert_true(!replied[id])
                  }
                }
              }
              if eof {
                while !connection.is_closed() {
                  @async.pause()
                }
              } else {
                while connection.pending_count() > 0 {
                  @async.pause()
                }
                assert_true(!connection.is_closed())
              }
              assert_eq(connection.pending_count(), 0)
              assert_eq(connection.abandoned_count(), 0)
              assert_eq(connection.in_flight_count(), 0)
              assert_eq(connection.waiting_count(), 0)
            })
          },
        )
        worker.wait()
      })
      let snapshot = metrics.snapshot()
      assert_eq(snapshot.in_flight, 0L)
      assert_eq(snapshot.in_flight_bytes, 0L)
      assert_eq(snapshot.waiting, 0L)
      assert_eq(snapshot.waiting_bytes, 0L)
    }
  })
}
