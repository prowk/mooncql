///|
fn marked_failure() -> Bytes raise {
  let w = @codec.Writer::new()
  w.i32(0x2100)
  w.string("permission denied")
  w.to_bytes()
}

///|
async test "query info paging batch and retry preserve causes without copying input secrets to diagnostics" {
  @async.with_timeout(6000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let legacy : Array[@client.MetricEvent] = []
      let diagnostics : Array[@client.DiagnosticEvent] = []
      let metrics = @client.Metrics::with_diagnostics(
        event => diagnostics.push(event),
        listener=event => legacy.push(event),
      )
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        for _ in 0..<5 {
          let request = receive(peer)
          respond(peer, request.header.stream, 0, marked_failure())
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
          let values : Array[@types.Value] = [Text("BINDING_SECRET_20261025")]
          let options = @protocol.QueryOptions::new(
            request_options=@protocol.RequestOptions::new(
              custom_payload=Map([("secret", Some(b"PAYLOAD_SECRET_20261025"))]),
            ),
          )
          for mode in 0..<5 {
            let caught : Error? = try {
              match mode {
                0 => ignore(session.query("query", values~, options~))
                1 => ignore(session.query_with_info("query", values~, options~))
                2 =>
                  ignore(
                    session.pages("query", values~, options~).next_with_info(),
                  )
                3 =>
                  session.batch(
                    [@client.SessionBatchStatement::query("query", values~)],
                    options~,
                  )
                _ =>
                  ignore(
                    session.query(
                      "query",
                      values~,
                      options~,
                      idempotent=true,
                      retry=@client.RetryPolicy::new(max_attempts=2),
                    ),
                  )
              }
              None
            } catch {
              error => Some(error)
            }
            guard caught is Some(error) else { fail("missing failure") }
            fn original(error : Error) -> Error raise {
              match error {
                @client.ExecutionError(cause, info) => {
                  assert_eq(info.coordinator.port, server.addr.port())
                  assert_eq(info.attempt_count, 1)
                  original(cause)
                }
                @client.RetryExhausted(failures) => {
                  assert_eq(failures.length(), 1)
                  original(failures[0].error)
                }
                _ => error
              }
            }
            let cause = original(error)
            assert_true(
              cause
              is @client.Server(
                { code: 0x2100, message: "permission denied", .. }
              ),
            )
            assert_true(
              !error.to_string().contains("BINDING_SECRET") &&
              !error.to_string().contains("PAYLOAD_SECRET"),
            )
          }
          assert_eq(session.active_count(), 0)
          assert_eq(metrics.operations_snapshot().retry_attempts, 0L)
        },
      )
      worker.wait()
      let events = legacy.filter_map(event => {
        match event {
          RequestFinished(event) => Some(event)
          _ => None
        }
      })
      assert_eq(events.length(), 5)
      for event in events {
        assert_true(event.outcome is ServerError(0x2100))
        assert_eq(event.endpoint.port, server.addr.port())
        assert_true(event.may_have_been_sent)
        assert_eq(event.phase, @client.WaitingResponse)
      }
      let times = diagnostics.filter_map(event => {
        match event {
          RpcTimeline(timing) => Some(timing)
          _ => None
        }
      })
      assert_eq(times.length(), 5)
      for index in 0..<times.length() {
        let timing = times[index]
        assert_eq(timing.request_id, (index + 1).to_int64())
        assert_true(
          timing.sending_at_ms is Some(sent) &&
          timing.queued_at_ms <= sent &&
          sent <= timing.completed_at_ms,
        )
      }
      for event in diagnostics {
        let text = event.to_repr().to_string()
        assert_true(
          !text.contains("BINDING_SECRET") && !text.contains("PAYLOAD_SECRET"),
        )
      }
      for event in legacy {
        let text = event.to_repr().to_string()
        assert_true(
          !text.contains("BINDING_SECRET") && !text.contains("PAYLOAD_SECRET"),
        )
      }
      assert_eq(metrics.snapshot().in_flight_bytes, 0L)
    })
  })
}
