///|
extern "C" fn now_ns() -> Int64 = "prowk_mooncql_bench_now_ns"

///|
extern "C" fn cpu_ns() -> Int64 = "prowk_mooncql_bench_cpu_ns"

///|
extern "C" fn peak_bytes() -> Int64 = "prowk_mooncql_bench_peak_bytes"

///|
fn integer(name : String, fallback : String) -> Int raise {
  @string.parse_int(@env.get_env_var(name).unwrap_or(fallback))
}

///|
fn row_body(kind : Int, rows : Int) -> Bytes raise {
  let w = @codec.Writer::new()
  w.i32(2)
  w.i32(1)
  let columns = if kind == 2 { 256 } else { 1 }
  w.i32(columns)
  w.string("ks")
  w.string("t")
  for column in 0..<columns {
    w.string("value\{column}")
    if kind == 1 {
      w.u16(3)
    } else {
      if kind == 3 {
        for _ in 0..<8 {
          w.u16(32)
        }
      }
      w.u16(9)
    }
  }
  w.i32(rows)
  for _ in 0..<rows {
    for _ in 0..<columns {
      if kind == 1 {
        @types.write_value(w, Bytes(Bytes::make(400000, b'x')))
      } else if kind == 3 {
        let mut value = @types.Value::ListValue(Array::make(1024, Integer(7)))
        for _ in 0..<7 {
          value = ListValue([value])
        }
        @types.write_value(w, value)
      } else {
        @types.write_value(w, Integer(7))
      }
    }
  }
  w.to_bytes()
}

///|
async fn abandoned(rounds : Int) -> Array[Int64] {
  let large = row_body(0, 100000)
  let samples = []
  @async.with_task_group(group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
    let release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
    let worker = group.spawn(() => {
      let (tcp, _) = server.accept()
      let peer = Peer::new(tcp)
      defer peer.close()
      handshake(peer)
      for _ in 0..<rounds {
        let late = receive(peer)
        seen.put(())
        release.get()
        respond(peer, late.header.stream, 8, large)
        let probe = receive(peer)
        respond(peer, probe.header.stream, 8, b"\x00\x00\x00\x01")
      }
      assert_eq(peer.read_some(), None)
    })
    @client.with_connection_builder(
      config=@client.ConnectionBuilder::new(port=server.addr.port()),
      connection => {
        @async.with_task_group(requests => {
          for _ in 0..<rounds {
            let request = requests.spawn(() => connection.query("late"))
            seen.get()
            request.cancel()
            ignore(request.wait()) catch {
              _ => ()
            }
            assert_eq(connection.abandoned_count(), 1)
            let start = now_ns()
            release.put(())
            while connection.pending_count() > 0 {
              @async.pause()
            }
            samples.push(now_ns() - start)
            assert_true(connection.query("probe") is Void)
            assert_eq(connection.in_flight_bytes(), 0L)
          }
        })
        receive_note(connection)
      },
    )
    worker.wait()
  })
  samples
}

///|
async fn mixed(rounds : Int) -> Array[Int64] {
  let bodies = Array::makei(4, kind => row_body(kind, 1))
  let samples = []
  @async.with_task_group(group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let worker = group.spawn(() => {
      let (tcp, _) = server.accept()
      let peer = Peer::new(tcp)
      defer peer.close()
      handshake(peer)
      for _ in 0..<rounds {
        let streams = []
        for _ in 0..<32 {
          streams.push(receive(peer))
        }
        for message in streams {
          let id = @string.parse_int(
            @codec.Reader::new(message.body).long_string(),
          )
          respond(peer, message.header.stream, 8, bodies[id % 4])
        }
      }
      assert_eq(peer.read_some(), None)
    })
    @client.with_connection_builder(
      config=@client.ConnectionBuilder::new(port=server.addr.port()),
      connection => {
        for _ in 0..<rounds {
          async fn operation(id : Int) -> Unit {
            let start = now_ns()
            guard connection.query(id.to_string()) is Rows(page) else {
              fail("missing mixed row")
            }
            assert_eq(page.rows.length(), 1)
            assert_eq(page.columns.length(), if id % 4 == 2 { 256 } else { 1 })
            if id % 4 == 0 {
              assert_eq(page.row(0).int("value0"), 7)
              samples.push(now_ns() - start)
            }
            if id % 4 == 1 {
              assert_eq(page.row(0).bytes("value0").length(), 400000)
            }
          }
          ignore(
            @async.all(
              Array::makei(32, id => () => operation(id)),
              max_concurrent=32,
            ),
          )
        }
        receive_note(connection)
      },
    )
    worker.wait()
  })
  samples
}

///|
async fn fairness(rounds : Int) -> Array[Int64] {
  let samples = []
  let values : Array[@types.Value] = [Bytes(Bytes::make(10000, b'x'))]
  let limit = @protocol.query("large", values~).body.length() + 9
  @async.with_task_group(group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
    let release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
    let started : @async.Queue[Unit] = @async.Queue(kind=Blocking(32))
    let worker = group.spawn(() => {
      let (tcp, _) = server.accept()
      let peer = Peer::new(tcp)
      defer peer.close()
      handshake(peer)
      for _ in 0..<rounds {
        let held = receive(peer)
        seen.put(())
        release.get()
        respond(peer, held.header.stream, 8, b"\x00\x00\x00\x01")
        for _ in 0..<33 {
          let request = receive(peer)
          respond(peer, request.header.stream, 8, b"\x00\x00\x00\x01")
        }
      }
      assert_eq(peer.read_some(), None)
    })
    @client.with_connection_builder(
      config=@client.ConnectionBuilder::new(
        port=server.addr.port(),
        max_in_flight_bytes=limit,
      ),
      connection => {
        for _ in 0..<rounds {
          @async.with_task_group(requests => {
            let held = requests.spawn(() => connection.query("held"))
            seen.get()
            let start = now_ns()
            let large = requests.spawn(() => connection.query("large", values~))
            while connection.waiting_count() != 1 {
              @async.pause()
            }
            let smalls = []
            for _ in 0..<32 {
              smalls.push(
                requests.spawn(() => {
                  started.put(())
                  connection.query("small")
                }),
              )
            }
            for _ in 0..<32 {
              started.get()
            }
            release.put(())
            ignore(held.wait())
            assert_true(large.wait() is Void)
            samples.push(now_ns() - start)
            for task in smalls {
              assert_true(task.wait() is Void)
            }
          })
          assert_eq(connection.waiting_count(), 0)
          assert_eq(connection.in_flight_count(), 0)
        }
        receive_note(connection)
      },
    )
    worker.wait()
  })
  samples
}

///|
async fn retry(rounds : Int) -> Array[Int64] {
  let samples = []
  let metrics = @client.Metrics::new()
  @async.with_task_group(group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let worker = group.spawn(() => {
      let (tcp, _) = server.accept()
      let peer = Peer::new(tcp)
      defer peer.close()
      handshake(peer)
      let overload = @codec.Writer::new()
      overload.i32(0x1001)
      overload.string("busy")
      for _ in 0..<rounds {
        for attempt in 0..<2 {
          let request = receive(peer)
          respond(
            peer,
            request.header.stream,
            if attempt == 0 {
              0
            } else {
              8
            },
            if attempt == 0 {
              overload.to_bytes()
            } else {
              b"\x00\x00\x00\x01"
            },
          )
        }
      }
      assert_eq(peer.read_some(), None)
    })
    @client.with_session_builder(
      config=@client.SessionBuilder::new(
        connection=@client.ConnectionBuilder::new(
          port=server.addr.port(),
          metrics~,
        ),
      ),
      session => {
        for _ in 0..<rounds {
          let start = now_ns()
          assert_true(
            session.query(
              "retry",
              idempotent=true,
              retry=@client.RetryPolicy::new(max_attempts=2, delay_ms=0),
            )
            is Void,
          )
          samples.push(now_ns() - start)
        }
        assert_eq(session.active_count(), 0)
      },
    )
    worker.wait()
  })
  assert_eq(metrics.snapshot().requests_started, rounds.to_int64() * 2L)
  samples
}

///|
async fn main {
  @async.with_timeout(60000, () => {
    let mode = @env.get_env_var("RELIABILITY_MODE").unwrap_or("mixed")
    let rounds = integer("RELIABILITY_ROUNDS", "16")
    assert_true(rounds >= 1 && rounds <= 256)
    let start = now_ns()
    let cpu = cpu_ns()
    let samples = match mode {
      "abandoned" => abandoned(rounds)
      "fairness" => fairness(rounds)
      "retry" => retry(rounds)
      "mixed" => mixed(rounds)
      _ => fail("invalid reliability mode")
    }
    let elapsed = now_ns() - start
    let cpu = cpu_ns() - cpu
    for index in 0..<samples.length() {
      let sample = samples[index]
      println("{\"type\":\"sample\",\"id\":\{index},\"latency_ns\":\{sample}}")
    }
    samples.sort()
    println(
      "{\"type\":\"summary\",\"mode\":\"\{mode}\",\"rounds\":\{rounds},\"count\":\{samples.length()},\"elapsed_ns\":\{elapsed},\"cpu_ns\":\{cpu},\"peak_memory_bytes\":\{peak_bytes()},\"p99_ns\":\{samples[(samples.length() * 99 + 99) / 100 - 1]},\"failures\":0}",
    )
  })
}
