///|
pub(all) enum RequestOutcome {
  Succeeded
  ServerError(Int)
  Timeout(TimeoutInfo)
  Cancelled
  LocalOverload(OverloadReason)
  Disconnected
  InvalidConfiguration
  TlsError
  AuthenticationError
  ProtocolError
  TransportError
  OtherFailure
} derive(@debug.Debug)

///|
pub extend RequestOutcome with @debug.Debug::{to_repr}

///|
pub(all) enum CacheEvent {
  Hit
  Miss
  Coalesced
  Evicted
} derive(Eq, @debug.Debug)

///|
pub extend CacheEvent with Eq::{equal, not_equal}

///|
pub extend CacheEvent with @debug.Debug::{to_repr}

///|
pub(all) enum WaitScope {
  Connection
  Prepare
  Retry
} derive(Eq, @debug.Debug)

///|
pub extend WaitScope with Eq::{equal, not_equal}

///|
pub extend WaitScope with @debug.Debug::{to_repr}

///|
/// 区分普通数据请求、控制连接请求和驱动自身发起的空闲心跳。
pub(all) enum RpcScope {
  Data
  Control
  Heartbeat
} derive(Eq, @debug.Debug)

///|
pub extend RpcScope with Eq::{equal, not_equal}

///|
pub extend RpcScope with @debug.Debug::{to_repr}

///|
/// 已接受的 Session API 调用类别，内部 RPC 与重试不会重复产生逻辑调用。
pub(all) enum OperationKind {
  QueryOperation
  PrepareOperation
  ExecuteOperation
  BatchOperation
  RequestOperation
  SchemaCheckOperation
  SchemaWaitOperation
  SchemaMetadataOperation
} derive(Eq, @debug.Debug)

///|
pub extend OperationKind with Eq::{equal, not_equal}

///|
pub extend OperationKind with @debug.Debug::{to_repr}

///|
/// 逻辑调用结束事件；耗时覆盖选连接、准备、重试及该调用内的 DDL 等待。
pub(all) struct OperationEvent {
  kind : OperationKind
  outcome : RequestOutcome
  elapsed_ms : Int64
} derive(@debug.Debug)

///|
pub extend OperationEvent with @debug.Debug::{to_repr}

///|
pub(all) struct RequestEvent {
  scope : RpcScope
  endpoint : Endpoint
  opcode : Int
  request_bytes : Int64
  outcome : RequestOutcome
  phase : TimeoutPhase
  may_have_been_sent : Bool
  queue_ms : Int64
  execution_ms : Int64
} derive(@debug.Debug)

///|
pub extend RequestEvent with @debug.Debug::{to_repr}

///|
pub(all) enum MetricEvent {
  RequestStarted(Endpoint, Int, Int64)
  RequestFinished(RequestEvent)
  ConnectionAttempt(Endpoint)
  ConnectionEstablished(Endpoint)
  ConnectionFailed(Endpoint, RequestOutcome)
  ConnectionClosed(Endpoint)
  Reconnected(Endpoint, Int, Bool)
  Cache(Endpoint, CacheEvent)
  WaitFinished(WaitScope, Int64, Int64, RequestOutcome)
  OperationStarted(OperationKind)
  OperationFinished(OperationEvent)
  RetryStarted(Endpoint, Int)
} derive(@debug.Debug)

///|
pub extend MetricEvent with @debug.Debug::{to_repr}

///|
pub(all) struct MetricsSnapshot {
  mut logical_started : Int64
  mut logical_succeeded : Int64
  mut logical_failed : Int64
  mut logical_cancelled : Int64
  mut logical_ms : Int64
  mut retry_attempts : Int64
  mut requests_started : Int64
  mut requests_succeeded : Int64
  mut requests_failed : Int64
  mut requests_cancelled : Int64
  mut request_timeouts : Int64
  mut queue_ms : Int64
  mut execution_ms : Int64
  mut in_flight : Int64
  mut in_flight_bytes : Int64
  mut waiting : Int64
  mut waiting_bytes : Int64
  mut peak_in_flight : Int64
  mut peak_in_flight_bytes : Int64
  mut peak_waiting : Int64
  mut peak_waiting_bytes : Int64
  mut connect_attempts : Int64
  mut connections_established : Int64
  mut connections_closed : Int64
  mut connect_failures : Int64
  mut connect_cancellations : Int64
  mut connect_timeouts : Int64
  mut reconnects : Int64
  mut control_reconnects : Int64
  mut cache_hits : Int64
  mut cache_misses : Int64
  mut cache_coalesced : Int64
  mut cache_evictions : Int64
  mut sent_frames : Int64
  mut sent_raw_payload_bytes : Int64
  mut sent_encoded_payload_bytes : Int64
  mut sent_complete_frame_bytes : Int64
  mut received_frames : Int64
  mut received_raw_payload_bytes : Int64
  mut received_encoded_payload_bytes : Int64
  mut received_complete_frame_bytes : Int64
  mut session_waits : Int64
  mut session_wait_failures : Int64
  mut session_wait_cancellations : Int64
  mut session_wait_ms : Int64
  mut session_wait_timeouts : Int64
  mut prepare_waits : Int64
  mut prepare_wait_ms : Int64
  mut prepare_wait_failures : Int64
  mut prepare_wait_cancellations : Int64
  mut prepare_wait_timeouts : Int64
  mut retry_waits : Int64
  mut retry_wait_ms : Int64
  mut retry_wait_failures : Int64
  mut retry_wait_cancellations : Int64
  mut retry_wait_timeouts : Int64
  mut listener_errors : Int64
} derive(@debug.Debug, ToJson)

///|
pub extend MetricsSnapshot with @debug.Debug::{to_repr}

///|
pub extend MetricsSnapshot with ToJson::{to_json}

///|
pub struct Metrics {
  data : MetricsSnapshot
  listener : ((MetricEvent) -> Unit raise)?
}

///|
pub fn Metrics::new(listener? : (MetricEvent) -> Unit raise) -> Metrics {
  {
    listener,
    data: {
      logical_started: 0L,
      logical_succeeded: 0L,
      logical_failed: 0L,
      logical_cancelled: 0L,
      logical_ms: 0L,
      retry_attempts: 0L,
      requests_started: 0L,
      requests_succeeded: 0L,
      requests_failed: 0L,
      requests_cancelled: 0L,
      request_timeouts: 0L,
      queue_ms: 0L,
      execution_ms: 0L,
      in_flight: 0L,
      in_flight_bytes: 0L,
      waiting: 0L,
      waiting_bytes: 0L,
      peak_in_flight: 0L,
      peak_in_flight_bytes: 0L,
      peak_waiting: 0L,
      peak_waiting_bytes: 0L,
      connect_attempts: 0L,
      connections_established: 0L,
      connections_closed: 0L,
      connect_failures: 0L,
      connect_cancellations: 0L,
      connect_timeouts: 0L,
      reconnects: 0L,
      control_reconnects: 0L,
      cache_hits: 0L,
      cache_misses: 0L,
      cache_coalesced: 0L,
      cache_evictions: 0L,
      sent_frames: 0L,
      sent_raw_payload_bytes: 0L,
      sent_encoded_payload_bytes: 0L,
      sent_complete_frame_bytes: 0L,
      received_frames: 0L,
      received_raw_payload_bytes: 0L,
      received_encoded_payload_bytes: 0L,
      received_complete_frame_bytes: 0L,
      session_waits: 0L,
      session_wait_failures: 0L,
      session_wait_cancellations: 0L,
      session_wait_ms: 0L,
      session_wait_timeouts: 0L,
      listener_errors: 0L,
      prepare_waits: 0L,
      prepare_wait_ms: 0L,
      prepare_wait_failures: 0L,
      prepare_wait_cancellations: 0L,
      prepare_wait_timeouts: 0L,
      retry_waits: 0L,
      retry_wait_ms: 0L,
      retry_wait_failures: 0L,
      retry_wait_cancellations: 0L,
      retry_wait_timeouts: 0L,
    },
  }
}

///|
pub fn Metrics::snapshot(self : Metrics) -> MetricsSnapshot {
  { ..self.data, }
}

///|
pub fn MetricsSnapshot::total_timeouts(self : MetricsSnapshot) -> Int64 {
  self.request_timeouts +
  self.connect_timeouts +
  self.session_wait_timeouts +
  self.prepare_wait_timeouts +
  self.retry_wait_timeouts
}

///|
pub fn MetricsSnapshot::total_cancellations(self : MetricsSnapshot) -> Int64 {
  self.requests_cancelled +
  self.connect_cancellations +
  self.session_wait_cancellations +
  self.prepare_wait_cancellations +
  self.retry_wait_cancellations
}

///|
pub fn MetricsSnapshot::sent_payload_ratio(self : MetricsSnapshot) -> Double {
  if self.sent_raw_payload_bytes == 0L {
    1.0
  } else {
    self.sent_encoded_payload_bytes.to_double() /
    self.sent_raw_payload_bytes.to_double()
  }
}

///|
pub fn MetricsSnapshot::received_payload_ratio(
  self : MetricsSnapshot,
) -> Double {
  if self.received_raw_payload_bytes == 0L {
    1.0
  } else {
    self.received_encoded_payload_bytes.to_double() /
    self.received_raw_payload_bytes.to_double()
  }
}

///|
fn Metrics::emit(self : Metrics, event : MetricEvent) -> Unit {
  if self.listener is Some(listener) {
    listener(event) catch {
      _ => self.data.listener_errors += 1L
    }
  }
}

///|
fn Metrics::cache(
  self : Metrics,
  endpoint : Endpoint,
  event : CacheEvent,
) -> Unit {
  match event {
    Hit => self.data.cache_hits += 1L
    Miss => self.data.cache_misses += 1L
    Coalesced => self.data.cache_coalesced += 1L
    Evicted => self.data.cache_evictions += 1L
  }
  self.emit(Cache(endpoint, event))
}

///|
pub async fn[G] connect(
  group : @async.TaskGroup[G],
  config? : Config = Config::new(),
  deadline? : Deadline,
) -> Connection {
  connect_observed(group, config, deadline, None)
}

///|
async fn[G] connect_observed(
  group : @async.TaskGroup[G],
  config : Config,
  deadline : Deadline?,
  shared : Admission?,
) -> Connection {
  guard config.metrics is Some(metrics) else {
    return connect_internal(group, config~, deadline?, shared?)
  }
  let endpoint = Endpoint::new(host=config.host, port=config.port)
  metrics.data.connect_attempts += 1L
  metrics.emit(ConnectionAttempt(endpoint))
  let mut completed = false
  defer (if !completed {
    metrics.data.connect_cancellations += 1L
    metrics.emit(ConnectionFailed(endpoint, Cancelled))
  })
  let result = Ok(connect_internal(group, config~, deadline?, shared?)) catch {
    error => Err(error)
  }
  completed = true
  match result {
    Ok(connection) => {
      metrics.data.connections_established += 1L
      metrics.emit(ConnectionEstablished(endpoint))
      connection
    }
    Err(error) => {
      metrics.data.connect_failures += 1L
      if request_outcome(error) is Timeout(_) {
        metrics.data.connect_timeouts += 1L
      }
      metrics.emit(ConnectionFailed(endpoint, request_outcome(error)))
      raise error
    }
  }
}

///|
fn Metrics::gauges(
  self : Metrics,
  in_flight : Int64,
  bytes : Int64,
  waiting : Int64,
  waiting_bytes : Int64,
) -> Unit {
  let data = self.data
  data.in_flight += in_flight
  data.in_flight_bytes += bytes
  data.waiting += waiting
  data.waiting_bytes += waiting_bytes
  if data.in_flight > data.peak_in_flight {
    data.peak_in_flight = data.in_flight
  }
  if data.in_flight_bytes > data.peak_in_flight_bytes {
    data.peak_in_flight_bytes = data.in_flight_bytes
  }
  if data.waiting > data.peak_waiting {
    data.peak_waiting = data.waiting
  }
  if data.waiting_bytes > data.peak_waiting_bytes {
    data.peak_waiting_bytes = data.waiting_bytes
  }
}

///|
fn request_outcome(error : Error) -> RequestOutcome {
  match error {
    ExecutionError(cause, _) => request_outcome(cause)
    SchemaMetadataError(_, cause) => request_outcome(cause)
    RetryExhausted(failures) =>
      if failures.is_empty() {
        OtherFailure
      } else {
        request_outcome(failures[failures.length() - 1].error)
      }
    Server(error) => ServerError(error.code)
    TimedOut(info) => Timeout(info)
    Overloaded(reason) => LocalOverload(reason)
    Closed | HeartbeatFailed | @io.ReaderClosed => Disconnected
    Configuration(_) => InvalidConfiguration
    TlsFailure(_) => TlsError
    Authentication(_) => AuthenticationError
    Unexpected(_) | @codec.CodecError(_) => ProtocolError
    @os_error.OSError(_, ..) => TransportError
    _ => OtherFailure
  }
}

///|
priv struct WaitObservation {
  metrics : Metrics
  scope : WaitScope
  bytes : Int64
  started : Int64
  mut outcome : RequestOutcome
  mut finished : Bool
}

///|
fn WaitObservation::new(
  metrics : Metrics,
  scope : WaitScope,
  bytes : Int64,
) -> WaitObservation {
  match scope {
    Connection => metrics.data.session_waits += 1L
    Prepare => metrics.data.prepare_waits += 1L
    Retry => metrics.data.retry_waits += 1L
  }
  {
    metrics,
    scope,
    bytes,
    started: @async.now(),
    outcome: Cancelled,
    finished: false,
  }
}

///|
fn WaitObservation::finish(self : WaitObservation) -> Unit {
  if self.finished {
    return
  }
  self.finished = true
  let duration = @async.now() - self.started
  let data = self.metrics.data
  if self.scope != Retry {
    data.queue_ms += duration
  }
  match self.scope {
    Connection => {
      data.session_wait_ms += duration
      match self.outcome {
        Succeeded => ()
        Cancelled => data.session_wait_cancellations += 1L
        Timeout(_) => {
          data.session_wait_timeouts += 1L
          data.session_wait_failures += 1L
        }
        _ => data.session_wait_failures += 1L
      }
    }
    Prepare => {
      data.prepare_wait_ms += duration
      match self.outcome {
        Succeeded => ()
        Cancelled => data.prepare_wait_cancellations += 1L
        Timeout(_) => {
          data.prepare_wait_timeouts += 1L
          data.prepare_wait_failures += 1L
        }
        _ => data.prepare_wait_failures += 1L
      }
    }
    Retry => {
      data.retry_wait_ms += duration
      match self.outcome {
        Succeeded => ()
        Cancelled => data.retry_wait_cancellations += 1L
        Timeout(_) => {
          data.retry_wait_timeouts += 1L
          data.retry_wait_failures += 1L
        }
        _ => data.retry_wait_failures += 1L
      }
    }
  }
  self.metrics.emit(
    WaitFinished(self.scope, self.bytes, duration, self.outcome),
  )
}

///|
priv struct RequestObservation {
  scope : RpcScope
  metrics : Metrics
  endpoint : Endpoint
  opcode : Int
  bytes : Int64
  started : Int64
  mut executing : Int64?
  mut outcome : RequestOutcome
}

///|
fn RequestObservation::new(
  metrics : Metrics,
  config : Config,
  request : @protocol.Request,
  scope : RpcScope,
) -> RequestObservation {
  let endpoint = Endpoint::new(host=config.host, port=config.port)
  let bytes = request.body.length().to_int64() + 9L
  let started = @async.now()
  metrics.data.requests_started += 1L
  metrics.emit(RequestStarted(endpoint, request.opcode, bytes))
  {
    scope,
    metrics,
    endpoint,
    opcode: request.opcode,
    bytes,
    started,
    executing: None,
    outcome: Cancelled,
  }
}

///|
fn RequestObservation::finish(
  self : RequestObservation,
  context : TimeoutContext,
) -> Unit {
  let finished = @async.now()
  let queue_ms = match self.executing {
    Some(started) => started - self.started
    None => finished - self.started
  }
  let execution_ms = match self.executing {
    Some(started) => finished - started
    None => 0L
  }
  let data = self.metrics.data
  match self.outcome {
    Succeeded => data.requests_succeeded += 1L
    Cancelled => data.requests_cancelled += 1L
    Timeout(_) => {
      data.requests_failed += 1L
      data.request_timeouts += 1L
    }
    _ => data.requests_failed += 1L
  }
  data.queue_ms += queue_ms
  data.execution_ms += execution_ms
  self.metrics.emit(
    RequestFinished({
      scope: self.scope,
      endpoint: self.endpoint,
      opcode: self.opcode,
      request_bytes: self.bytes,
      outcome: self.outcome,
      phase: context.phase,
      may_have_been_sent: context.sent,
      queue_ms,
      execution_ms,
    }),
  )
}

///|
pub async fn Connection::request(
  self : Connection,
  request : @protocol.Request,
  cached? : Array[@protocol.Column] = [],
  deadline? : Deadline,
) -> Reply {
  self.request_measured(request, cached, deadline, self.rpc_scope)
}

///|
async fn Connection::request_measured(
  self : Connection,
  request : @protocol.Request,
  cached : Array[@protocol.Column],
  deadline : Deadline?,
  scope : RpcScope,
) -> Reply {
  let context = TimeoutContext::{ phase: WaitingSlot, sent: false, }
  let observation = match self.config.metrics {
    Some(metrics) =>
      Some(RequestObservation::new(metrics, self.config, request, scope))
    None => None
  }
  defer (if observation is Some(observation) { observation.finish(context) })
  let outcome = Ok(
    self.request_internal(request, cached, deadline, context, observation),
  ) catch {
    error => Err(error)
  }
  match outcome {
    Ok(reply) => {
      if observation is Some(observation) {
        observation.outcome = match reply.response {
          Failure(error) => ServerError(error.code)
          _ => Succeeded
        }
      }
      reply
    }
    Err(error) => {
      if observation is Some(observation) {
        observation.outcome = request_outcome(error)
      }
      raise error
    }
  }
}
