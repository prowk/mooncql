///|
priv suberror ListenerFailed

///|
async test "UNPREPARED recovery lock has a bounded byte charged waiter and cancellation releases it" {
  @async.with_timeout(7000, () => {
    @async.with_task_group(group => {
      let metrics = @client.Metrics::new()
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let prepare = receive(peer)
        respond(peer, prepare.header.stream, 8, prepared_result(b"old"))
        let first = receive(peer)
        let second = receive(peer)
        respond(peer, first.header.stream, 0, unprepared_error(b"old"))
        let recovery = receive(peer)
        assert_eq(recovery.header.opcode, 9)
        seen.put(())
        respond(peer, second.header.stream, 0, unprepared_error(b"old"))
        let excess = receive(peer)
        assert_eq(excess.header.opcode, 10)
        respond(peer, excess.header.stream, 0, unprepared_error(b"old"))
        release.get()
        respond(peer, recovery.header.stream, 8, prepared_result(b"new"))
        let execute = receive(peer)
        let r = @codec.Reader::new(execute.body)
        assert_eq(r.short_bytes(), b"new")
        assert_eq(r.short_bytes(), b"metadata")
        assert_eq(r.u16(), 10)
        assert_eq(r.i32(), 3)
        assert_eq(r.u16(), 1)
        assert_eq(r.bytes(), Some(@types.encode_scalar(Integer(1))))
        respond(peer, execute.header.stream, 8, session_row(1))
        assert_eq(peer.read_some(), None)
      })
      @client.with_connection_builder(
        config=@client.ConnectionBuilder::new(
          port=server.addr.port(),
          max_in_flight=2,
          max_waiting=1,
          metrics~,
        ),
        connection => {
          let statement = connection.prepare("prepared")
          let options = @protocol.QueryOptions::new(skip_metadata=true)
          @async.with_task_group(requests => {
            let first = requests.spawn(() => {
              statement.execute([Integer(1)], options~)
            })
            let second = requests.spawn(() => {
              statement.execute([Integer(2)], options~)
            })
            seen.get()
            while metrics.snapshot().waiting != 1L {
              @async.pause()
            }
            assert_true(metrics.snapshot().waiting_bytes > 0L)
            assert_true(
              try {
                ignore(statement.execute([Integer(3)], options~))
                false
              } catch {
                @client.Overloaded(WaitingQueueFull) => true
                _ => false
              },
            )
            second.cancel()
            ignore(second.wait()) catch {
              _ => ()
            }
            assert_eq(metrics.snapshot().waiting, 0L)
            assert_eq(metrics.snapshot().waiting_bytes, 0L)
            release.put(())
            assert_true(first.wait() is Rows(_))
          })
        },
      )
      worker.wait()
      let data = metrics.snapshot()
      assert_true(data.prepare_wait_failures >= 1L)
      assert_eq(data.prepare_wait_cancellations, 1L)
      assert_eq(data.in_flight, 0L)
      assert_eq(data.in_flight_bytes, 0L)
      assert_eq(data.waiting, 0L)
      assert_eq(data.waiting_bytes, 0L)
    })
  })
}

///|
async test "session connection wait timeout and cancelled handshake remain observable and drain" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let metrics = @client.Metrics::new()
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        assert_eq(receive(peer).header.opcode, 5)
        seen.put(())
        assert_eq(peer.read_some(), None)
      })
      @client.with_session_builder(
        config=@client.SessionBuilder::new(
          connection=@client.ConnectionBuilder::new(
            port=server.addr.port(),
            connect_timeout_ms=4000,
            metrics~,
          ),
        ),
        session => {
          @async.with_task_group(requests => {
            let first = requests.spawn(() => {
              try {
                ignore(session.query("waiting"))
                false
              } catch {
                @client.Closed => true
                _ => false
              }
            })
            seen.get()
            assert_true(
              try {
                ignore(
                  session.query(
                    "waiting timeout",
                    deadline=@client.Deadline::after(400),
                  ),
                )
                false
              } catch {
                @client.TimedOut(info) => info.phase == WaitingConnection
                _ => false
              },
            )
            assert_eq(metrics.snapshot().waiting, 1L)
            session.close()
            assert_true(first.wait())
          })
        },
      )
      worker.wait()
      let data = metrics.snapshot()
      assert_eq(data.requests_started, 0L)
      assert_eq(data.session_waits, 2L)
      assert_eq(data.session_wait_timeouts, 1L)
      assert_eq(data.session_wait_failures, 2L)
      assert_eq(data.connect_attempts, 1L)
      assert_eq(data.connect_cancellations, 1L)
      assert_eq(data.total_timeouts(), 1L)
      assert_eq(data.total_cancellations(), 1L)
      assert_eq(data.waiting, 0L)
      assert_eq(data.waiting_bytes, 0L)
    })
  })
}

///|
async test "retry backoff timeout is distinct from request execution timeout" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let metrics = @client.Metrics::new()
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let request = receive(peer)
        respond(peer, request.header.stream, 0, overload_error())
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
          wait_session_nodes(session, 1)
          assert_true(
            try {
              ignore(
                session.query(
                  "read",
                  idempotent=true,
                  deadline=@client.Deadline::after(400),
                  retry=@client.RetryPolicy::new(delay_ms=3000),
                ),
              )
              false
            } catch {
              @client.RetryExhausted(failures) => failures.length() == 2
              _ => false
            },
          )
          session.close()
        },
      )
      worker.wait()
      let data = metrics.snapshot()
      assert_eq(data.requests_failed, 1L)
      assert_eq(data.request_timeouts, 0L)
      assert_eq(data.retry_wait_timeouts, 1L)
      assert_eq(data.total_timeouts(), 1L)
      assert_true(data.retry_wait_ms >= 200L)
    })
  })
}

///|
async test "throwing listener cannot break requests timeout cancellation or bounded queue gauges" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let events : Array[@client.MetricEvent] = []
      let metrics = @client.Metrics::new(listener=fn(event) raise {
        events.push(event)
        raise ListenerFailed
      })
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let first = receive(peer)
        assert_eq(@codec.Reader::new(first.body).long_string(), "first")
        seen.put(())
        release.get()
        respond(peer, first.header.stream, 8, b"\x00\x00\x00\x01")
        let last = receive(peer)
        assert_eq(@codec.Reader::new(last.body).long_string(), "last")
        respond(peer, last.header.stream, 8, b"\x00\x00\x00\x01")
        assert_eq(peer.read_some(), None)
      })
      @client.with_connection_builder(
        config=@client.ConnectionBuilder::new(
          port=server.addr.port(),
          max_in_flight=1,
          max_waiting=1,
          queue_timeout_ms=800,
          timeout_ms=3000,
          operation_timeout_ms=4000,
          metrics~,
        ),
        connection => {
          @async.with_task_group(requests => {
            let first = requests.spawn(() => connection.query("first"))
            seen.get()
            assert_eq(metrics.snapshot().in_flight, 1L)
            assert_true(
              try {
                ignore(connection.query("times out in queue"))
                false
              } catch {
                @client.TimedOut(info) =>
                  info.scope == Queue && !info.may_have_been_sent
                _ => false
              },
            )
            assert_eq(metrics.snapshot().waiting, 0L)
            let waiter = requests.spawn(() => {
              connection.query("cancelled in queue")
            })
            while metrics.snapshot().waiting != 1L {
              @async.pause()
            }
            assert_true(
              try {
                ignore(connection.query("rejected"))
                false
              } catch {
                @client.Overloaded(WaitingQueueFull) => true
                _ => false
              },
            )
            waiter.cancel()
            ignore(waiter.wait()) catch {
              _ => ()
            }
            assert_eq(metrics.snapshot().waiting, 0L)
            release.put(())
            assert_true(first.wait() is Void)
          })
          assert_true(connection.query("last") is Void)
          connection.shutdown()
        },
      )
      worker.wait()
      let data = metrics.snapshot()
      assert_eq(data.requests_started, 5L)
      assert_eq(data.requests_succeeded, 2L)
      assert_eq(data.requests_failed, 2L)
      assert_eq(data.requests_cancelled, 1L)
      assert_eq(data.request_timeouts, 1L)
      assert_eq(data.in_flight, 0L)
      assert_eq(data.in_flight_bytes, 0L)
      assert_eq(data.waiting, 0L)
      assert_eq(data.waiting_bytes, 0L)
      assert_eq(data.peak_in_flight, 1L)
      assert_eq(data.peak_waiting, 1L)
      assert_true(data.queue_ms >= 100L)
      assert_true(data.execution_ms >= 100L)
      assert_eq(data.listener_errors, events.length().to_int64())
      assert_eq(data.connections_established, 1L)
      assert_eq(data.connections_closed, 1L)
      assert_true(
        events.any(event => {
          event is RequestFinished({ outcome: Timeout(_), .. })
        }),
      )
      assert_true(
        events.any(event => event is RequestFinished({ outcome: Cancelled, .. })),
      )
      assert_true(
        events.any(event => {
          event is RequestFinished({ outcome: LocalOverload(_), .. })
        }),
      )
      // 快照的公开可变字段只属于调用方。
      data.in_flight = 999L
      assert_eq(metrics.snapshot().in_flight, 0L)
    })
  })
}

///|
fn metric_blob_rows(payload : Bytes) -> Bytes raise {
  let w = @codec.Writer::new()
  w.i32(2)
  w.i32(1)
  w.i32(1)
  w.string("ks")
  w.string("t")
  w.string("data")
  w.u16(3)
  w.i32(1)
  @types.write_value(w, Bytes(payload))
  w.to_bytes()
}

///|
async test "frame counters measure raw and compressed large payloads without exposing their data" {
  for compression in [false, true] {
    @async.with_timeout(5000, () => {
      @async.with_task_group(group => {
        let metrics = @client.Metrics::new()
        let payload = Bytes::from_array(Array::make(400000, b'A'))
        let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
        defer server.close()
        let worker = group.spawn(() => {
          let (tcp, _) = server.accept()
          let peer = Peer::new(tcp, compressed=compression)
          defer peer.close()
          handshake(peer)
          let request = receive(peer)
          assert_true(request.body.length() > payload.length())
          respond(peer, request.header.stream, 8, metric_blob_rows(payload))
          assert_eq(peer.read_some(), None)
        })
        @client.with_connection_builder(
          config=@client.ConnectionBuilder::new(
            port=server.addr.port(),
            compression~,
            metrics~,
          ),
          connection => {
            guard connection.query("echo", values=[Bytes(payload)])
              is Rows(page) else {
              fail("missing blob result")
            }
            assert_eq(page.get(0, "data"), @types.Value::Bytes(payload))
          },
        )
        worker.wait()
        let data = metrics.snapshot()
        assert_eq(data.requests_succeeded, 1L)
        assert_eq(data.sent_frames, 4L)
        assert_eq(data.received_frames, 4L)
        assert_true(data.sent_raw_payload_bytes > 400000L)
        assert_true(data.received_raw_payload_bytes > 400000L)
        let overhead = if compression { 12L } else { 10L }
        assert_eq(
          data.sent_complete_frame_bytes,
          data.sent_encoded_payload_bytes + overhead * data.sent_frames,
        )
        assert_eq(
          data.received_complete_frame_bytes,
          data.received_encoded_payload_bytes + overhead * data.received_frames,
        )
        if compression {
          assert_true(data.sent_payload_ratio() < 0.05)
          assert_true(data.received_payload_ratio() < 0.05)
        } else {
          assert_eq(data.sent_payload_ratio(), 1.0)
          assert_eq(data.received_payload_ratio(), 1.0)
        }
        assert_eq(data.in_flight, 0L)
        assert_eq(data.in_flight_bytes, 0L)
      })
    })
  }
}

///|
async test "cache metrics distinguish hit miss coalescing and eviction" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let metrics = @client.Metrics::new()
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let prepare = receive(peer)
        seen.put(())
        release.get()
        respond(peer, prepare.header.stream, 8, prepared_result(b"one"))
        let next = receive(peer)
        assert_eq(@codec.Reader::new(next.body).long_string(), "two")
        respond(peer, next.header.stream, 8, prepared_result(b"two"))
        assert_eq(peer.read_some(), None)
      })
      @client.with_connection_builder(
        config=@client.ConnectionBuilder::new(
          port=server.addr.port(),
          prepared_cache_capacity=1,
          metrics~,
        ),
        connection => {
          @async.with_task_group(requests => {
            let owner = requests.spawn(() => connection.prepare("one"))
            seen.get()
            let follower = requests.spawn(() => connection.prepare("one"))
            while metrics.snapshot().cache_coalesced == 0L {
              @async.pause()
            }
            @async.sleep(80)
            release.put(())
            ignore(owner.wait())
            ignore(follower.wait())
          })
          ignore(connection.prepare("one"))
          ignore(connection.prepare("two"))
        },
      )
      worker.wait()
      let data = metrics.snapshot()
      assert_eq(data.cache_hits, 1L)
      assert_eq(data.cache_misses, 3L)
      assert_eq(data.cache_coalesced, 1L)
      assert_eq(data.cache_evictions, 1L)
      assert_eq(data.requests_started, 2L)
      assert_true(data.prepare_wait_ms >= 50L)
      assert_eq(data.waiting, 0L)
      assert_eq(data.waiting_bytes, 0L)
    })
  })
}

///|
async test "session prepared replacement lock bounds waiters cancels cleanly and reports reconnect" {
  @async.with_timeout(7000, () => {
    @async.with_task_group(group => {
      let metrics = @client.Metrics::new()
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let worker = group.spawn(() => {
        {
          let (tcp, _) = server.accept()
          let peer = Peer::new(tcp)
          defer peer.close()
          handshake(peer)
          let prepare = receive(peer)
          respond(peer, prepare.header.stream, 8, prepared_result(b"old"))
          let query = receive(peer)
          assert_eq(@codec.Reader::new(query.body).long_string(), "disconnect")
        }
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let prepare = receive(peer)
        seen.put(())
        release.get()
        respond(peer, prepare.header.stream, 8, prepared_result(b"new"))
        let execute = receive(peer)
        assert_eq(execute.header.opcode, 10)
        respond(peer, execute.header.stream, 8, session_row(7))
        assert_eq(peer.read_some(), None)
      })
      @client.with_session_builder(
        config=@client.SessionBuilder::new(
          connection=@client.ConnectionBuilder::new(
            port=server.addr.port(),
            // 保留一个空闲 RPC 槽，专门验证准备互斥等待，而非满载节点选择等待。
            max_in_flight=2,
            max_waiting=1,
            metrics~,
          ),
        ),
        session => {
          let statement = session.prepare("prepared")
          assert_true(
            try {
              ignore(session.query("disconnect"))
              false
            } catch {
              _ => true
            },
          )
          @async.with_task_group(requests => {
            let owner = requests.spawn(() => {
              statement.execute(
                [Integer(7)],
                options=@protocol.QueryOptions::new(skip_metadata=true),
              )
            })
            seen.get()
            let waiter = requests.spawn(() => statement.execute([Integer(8)]))
            while metrics.snapshot().waiting != 1L {
              @async.pause()
            }
            assert_true(
              try {
                ignore(statement.execute([Integer(9)]))
                false
              } catch {
                @client.Overloaded(WaitingQueueFull) => true
                _ => false
              },
            )
            waiter.cancel()
            ignore(waiter.wait()) catch {
              _ => ()
            }
            assert_eq(metrics.snapshot().waiting, 0L)
            release.put(())
            assert_true(owner.wait() is Rows(_))
          })
          session.close()
        },
      )
      worker.wait()
      let data = metrics.snapshot()
      assert_eq(data.reconnects, 1L)
      assert_eq(data.connections_established, 2L)
      assert_eq(data.connections_closed, 2L)
      assert_true(data.prepare_wait_failures >= 1L)
      assert_true(data.prepare_wait_cancellations >= 1L)
      assert_eq(data.in_flight, 0L)
      assert_eq(data.in_flight_bytes, 0L)
      assert_eq(data.waiting, 0L)
      assert_eq(data.waiting_bytes, 0L)
    })
  })
}

///|
async test "cancelled sent request keeps observed quota until late response is consumed" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let metrics = @client.Metrics::new()
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let request = receive(peer)
        seen.put(())
        release.get()
        respond(peer, request.header.stream, 8, b"\x00\x00\x00\x01")
        let next = receive(peer)
        respond(peer, next.header.stream, 8, b"\x00\x00\x00\x01")
        assert_eq(peer.read_some(), None)
      })
      @client.with_connection_builder(
        config=@client.ConnectionBuilder::new(port=server.addr.port(), metrics~),
        connection => {
          @async.with_task_group(requests => {
            let task = requests.spawn(() => {
              connection.query("sent then cancelled")
            })
            seen.get()
            task.cancel()
            ignore(task.wait()) catch {
              _ => ()
            }
          })
          assert_eq(metrics.snapshot().requests_cancelled, 1L)
          assert_eq(metrics.snapshot().in_flight, 1L)
          assert_eq(connection.abandoned_count(), 1)
          release.put(())
          assert_true(connection.query("after late reply") is Void)
          assert_eq(metrics.snapshot().in_flight, 0L)
          assert_eq(connection.abandoned_count(), 0)
        },
      )
      worker.wait()
    })
  })
}
