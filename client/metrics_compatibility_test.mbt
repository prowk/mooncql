///|
fn legacy_metrics_snapshot(
  value : @client.MetricsSnapshot,
) -> @client.MetricsSnapshot {
  {
    requests_started: value.requests_started,
    requests_succeeded: value.requests_succeeded,
    requests_failed: value.requests_failed,
    requests_cancelled: value.requests_cancelled,
    request_timeouts: value.request_timeouts,
    queue_ms: value.queue_ms,
    execution_ms: value.execution_ms,
    in_flight: value.in_flight,
    in_flight_bytes: value.in_flight_bytes,
    waiting: value.waiting,
    waiting_bytes: value.waiting_bytes,
    peak_in_flight: value.peak_in_flight,
    peak_in_flight_bytes: value.peak_in_flight_bytes,
    peak_waiting: value.peak_waiting,
    peak_waiting_bytes: value.peak_waiting_bytes,
    connect_attempts: value.connect_attempts,
    connections_established: value.connections_established,
    connections_closed: value.connections_closed,
    connect_failures: value.connect_failures,
    connect_cancellations: value.connect_cancellations,
    connect_timeouts: value.connect_timeouts,
    reconnects: value.reconnects,
    control_reconnects: value.control_reconnects,
    cache_hits: value.cache_hits,
    cache_misses: value.cache_misses,
    cache_coalesced: value.cache_coalesced,
    cache_evictions: value.cache_evictions,
    sent_frames: value.sent_frames,
    sent_raw_payload_bytes: value.sent_raw_payload_bytes,
    sent_encoded_payload_bytes: value.sent_encoded_payload_bytes,
    sent_complete_frame_bytes: value.sent_complete_frame_bytes,
    received_frames: value.received_frames,
    received_raw_payload_bytes: value.received_raw_payload_bytes,
    received_encoded_payload_bytes: value.received_encoded_payload_bytes,
    received_complete_frame_bytes: value.received_complete_frame_bytes,
    session_waits: value.session_waits,
    session_wait_failures: value.session_wait_failures,
    session_wait_cancellations: value.session_wait_cancellations,
    session_wait_ms: value.session_wait_ms,
    session_wait_timeouts: value.session_wait_timeouts,
    prepare_waits: value.prepare_waits,
    prepare_wait_ms: value.prepare_wait_ms,
    prepare_wait_failures: value.prepare_wait_failures,
    prepare_wait_cancellations: value.prepare_wait_cancellations,
    prepare_wait_timeouts: value.prepare_wait_timeouts,
    retry_waits: value.retry_waits,
    retry_wait_ms: value.retry_wait_ms,
    retry_wait_failures: value.retry_wait_failures,
    retry_wait_cancellations: value.retry_wait_cancellations,
    retry_wait_timeouts: value.retry_wait_timeouts,
    listener_errors: value.listener_errors,
  }
}

///|
fn legacy_metricevent(value : @client.MetricEvent) -> Unit {
  match value {
    @client.RequestStarted(_, _, _) => ()
    @client.RequestFinished(_) => ()
    @client.ConnectionAttempt(_) => ()
    @client.ConnectionEstablished(_) => ()
    @client.ConnectionFailed(_, _) => ()
    @client.ConnectionClosed(_) => ()
    @client.Reconnected(_, _, _) => ()
    @client.Cache(_, _) => ()
    @client.WaitFinished(_, _, _, _) => ()
  }
}

///|
fn legacy_requestoutcome(value : @client.RequestOutcome) -> Unit {
  match value {
    @client.Succeeded => ()
    @client.ServerError(_) => ()
    @client.Timeout(_) => ()
    @client.Cancelled => ()
    @client.LocalOverload(_) => ()
    @client.Disconnected => ()
    @client.InvalidConfiguration => ()
    @client.TlsError => ()
    @client.ProtocolError => ()
    @client.TransportError => ()
    @client.OtherFailure => ()
  }
}

///|
test "0.2.0 complete diagnostic records and exhaustive enum matches remain source compatible" {
  let metrics = @client.Metrics::new()
  assert_eq(legacy_metrics_snapshot(metrics.snapshot()).requests_started, 0L)
  let request : @client.RequestEvent = {
    endpoint: @client.Endpoint::new(),
    opcode: 7,
    request_bytes: 10L,
    outcome: Succeeded,
    phase: WaitingSlot,
    may_have_been_sent: false,
    queue_ms: 0L,
    execution_ms: 0L,
  }
  legacy_metricevent(RequestFinished(request))
  legacy_requestoutcome(OtherFailure)
  let copy = metrics.operations_snapshot()
  copy.logical_started = 100L
  assert_eq(metrics.operations_snapshot().logical_started, 0L)
}
