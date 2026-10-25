///|
async test "classified exponential backoff changes real retries and retains logical RPC accounting" {
  @async.with_timeout(4000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let times = []
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        for code in [0x1001, 0x1002, 0] {
          let request = receive(peer)
          times.push(@async.now())
          if code != 0 {
            let w = @codec.Writer::new()
            w.i32(code)
            w.string("busy")
            respond(peer, request.header.stream, 0, w.to_bytes())
          } else {
            respond(peer, request.header.stream, 8, b"\x00\x00\x00\x01")
          }
        }
        assert_eq(peer.read_some(), None)
      })
      let metrics = @client.Metrics::new()
      @client.with_session(
        config=@client.SessionConfig::new(
          connection=@client.Config::new(port=server.addr.port(), metrics~),
          execution_profile=@client.ExecutionProfile::new(
            retry=@client.RetryPolicy::new(max_attempts=3, delay_ms=1000),
            backoff=@client.RetryBackoff::new(
              overloaded_ms=10,
              bootstrapping_ms=7,
              max_delay_ms=100,
              jitter=0.0,
            ),
          ),
        ),
        session => {
          let result = session.query_with_info(
            "explicitly idempotent",
            idempotent=true,
            deadline=@client.Deadline::after(2000),
          )
          assert_true(result.value is Void)
          assert_eq(result.info.attempt_count, 3)
          assert_eq(times.length(), 3)
          assert_true(times[1] - times[0] >= 10L)
          assert_true(times[2] - times[1] >= 14L)
          let snapshot = metrics.snapshot()
          assert_eq(snapshot.logical_started, 1L)
          assert_eq(snapshot.requests_started, 3L)
          assert_eq(snapshot.retry_attempts, 2L)
          session.close()
          assert_eq(session.resources().background_task_handles, 0)
        },
      )
      worker.wait()
    })
  })
}

///|
async test "classified backoff shares operation deadline and Session close wakes long delay without another RPC" {
  for closing in [false, true] {
    @async.with_timeout(4000, () => {
      @async.with_task_group(group => {
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
        let metrics = @client.Metrics::new()
        @client.with_session(
          config=@client.SessionConfig::new(
            connection=@client.Config::new(port=server.addr.port(), metrics~),
            execution_profile=@client.ExecutionProfile::new(
              backoff=@client.RetryBackoff::new(
                overloaded_ms=100000,
                max_delay_ms=100000,
                jitter=0.0,
              ),
            ),
          ),
          session => {
            @async.with_task_group(requests => {
              let caller = requests.spawn(() => {
                try {
                  ignore(
                    session.query(
                      "explicitly idempotent",
                      idempotent=true,
                      deadline=@client.Deadline::after(
                        if closing {
                          2000
                        } else {
                          100
                        },
                      ),
                    ),
                  )
                  false
                } catch {
                  @client.RetryExhausted(history) => {
                    assert_eq(history.length(), 2)
                    assert_true(history[0].error is @client.Server(_))
                    if closing {
                      history[1].error is @client.Closed
                    } else {
                      history[1].error is @client.TimedOut(info) &&
                      info.phase == WaitingRetry
                    }
                  }
                  _ => false
                }
              })
              while metrics.snapshot().retry_waits == 0L {
                @async.pause()
              }
              if closing {
                session.close()
              }
              assert_true(caller.wait())
            })
            session.close()
            assert_eq(metrics.snapshot().requests_started, 1L)
            assert_eq(metrics.snapshot().logical_failed, 1L)
            assert_eq(metrics.snapshot().retry_attempts, 0L)
            assert_eq(session.resources().background_task_handles, 0)
            assert_eq(session.budget().in_flight_bytes, 0L)
          },
        )
        worker.wait()
      })
    })
  }
}
