///|
fn model_random(state : Array[UInt], bound : Int) -> Int {
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
    let random = [seed]
    for round in 0..<rounds {
      errdefer println(
        "replay CQL_TEST_SEED=\{seed} CQL_TEST_ROUNDS=\{round + 1}; phase=multiplex round=\{round}",
      )
      let compressed = round % 2 == 0
      let order = Array::makei(12, index => index)
      for index in 0..<12 {
        let other = model_random(random, 12)
        let saved = order[index]
        order[index] = order[other]
        order[other] = saved
      }
      let cancelled = Array::make(12, false)
      for _ in 0..<4 {
        cancelled[model_random(random, 12)] = true
      }
      let eof = round % 3 == 0
      let completed = if eof { 1 + model_random(random, 10) } else { 12 }
      let replied = Array::make(12, false)
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
          let streams = Array::make(12, -1)
          for _ in 0..<12 {
            let message = receive(peer)
            let id = @string.parse_int(
              @codec.Reader::new(message.body).long_string(),
            )
            assert_true(id >= 0 && id < 12 && streams[id] == -1)
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
            let width = 1 + model_random(random, 31)
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
            max_in_flight=12,
            metrics~,
          ),
          connection => {
            @async.with_task_group(requests => {
              let tasks = []
              for id in 0..<12 {
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
              assert_eq(connection.pending_count(), 12)
              let mut cancelled_count = 0
              for id in 0..<12 {
                if cancelled[id] {
                  tasks[id].cancel()
                  ignore(tasks[id].wait()) catch {
                    _ => ()
                  }
                  cancelled_count += 1
                }
              }
              assert_eq(connection.abandoned_count(), cancelled_count)
              assert_eq(connection.in_flight_count(), 12)
              release.put(())
              for id in 0..<12 {
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
