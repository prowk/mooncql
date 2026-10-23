///|
test "Prometheus histogram buckets are cumulative with finite sum and an explicit infinity bucket" {
  let histogram = Histogram::new()
  histogram.observe(1L)
  histogram.observe(25L)
  let lines = []
  histogram.write(lines, "probe_seconds", "scope=\"data\"")
  assert_eq(histogram.count, 2L)
  assert_eq(histogram.sum_ms, 26L)
  assert_eq(histogram.buckets, [0L, 1L, 1L, 1L, 2L, 2L, 2L, 2L, 2L, 2L, 2L])
  assert_true(
    lines.contains("probe_seconds_bucket{scope=\"data\",le=\"+Inf\"} 2"),
  )
  assert_true(lines.contains("probe_seconds_sum{scope=\"data\"} 0.026"))
}

///|
test "changing endpoints cannot create unbounded series and unknown opcodes have one fixed label" {
  let meter = Meter::new(max_nodes=2)
  for index in 0..<100 {
    meter.observe(
      RequestFinished({
        endpoint: @client.Endpoint::new(port=10000 + index),
        scope: Data,
        opcode: 99 + index,
        request_bytes: 9L,
        outcome: Succeeded,
        phase: WaitingResponse,
        may_have_been_sent: true,
        queue_ms: 1L,
        execution_ms: 25L,
      }),
    )
  }
  assert_eq(meter.nodes.length(), 3)
  assert_eq(meter.overflow_events, 98L)
  let overflow = meter.nodes["other"]
  assert_eq(overflow.rpc[6 * 13], 98L)
  assert_eq(overflow.queue[0].count, 98L)
  assert_eq(overflow.execution[0].sum_ms, 2450L)
  assert_eq(escaped("a\"\\\nb"), "a\\\"\\\\\\nb")
}

///|
test "logical overload and retry counters remain separate from heartbeat and control RPCs" {
  let meter = Meter::new()
  let endpoint = @client.Endpoint::new()
  meter.observe(OperationStarted(QueryOperation))
  meter.observe(
    OperationFinished({
      kind: QueryOperation,
      outcome: LocalOverload(SessionInFlightLimit),
      elapsed_ms: 10L,
    }),
  )
  meter.observe(RetryStarted(endpoint, 2))
  for scope in [@client.RpcScope::Control, Heartbeat] {
    meter.observe(
      RequestFinished({
        endpoint,
        scope,
        opcode: 5,
        request_bytes: 9L,
        outcome: Succeeded,
        phase: WaitingResponse,
        may_have_been_sent: true,
        queue_ms: 0L,
        execution_ms: 1L,
      }),
    )
  }
  assert_eq(meter.started[0], 1L)
  assert_eq(meter.logical[5], 1L)
  assert_eq(meter.logical_overloads[5], 1L)
  assert_eq(meter.nodes["127.0.0.1:9042"].retries, 1L)
  assert_eq(meter.nodes["127.0.0.1:9042"].queue[0].count, 0L)
  assert_eq(meter.nodes["127.0.0.1:9042"].queue[1].count, 1L)
  assert_eq(meter.nodes["127.0.0.1:9042"].queue[2].count, 1L)
}
