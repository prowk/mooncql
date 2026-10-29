///|
pub(all) suberror DriverError {
  Closed
  Unexpected(String)
  Authentication(String)
  TlsFailure(String)
  Server(@protocol.ServerError)
  TimedOut(TimeoutInfo)
  Configuration(String)
  Overloaded(OverloadReason)
  AbandonedLimitExceeded
  AbandonedRequestExpired
  HeartbeatFailed
} derive(@debug.Debug)

///|
pub extend DriverError with @debug.Debug::{to_repr}

///|
pub(all) struct ConnectionBuilder {
  host : String
  port : Int32
  username : String?
  password : String?
  auth_provider : AuthProvider?
  max_auth_rounds : Int32
  max_auth_token_bytes : Int32
  timeout_ms : Int32
  connect_timeout_ms : Int32
  queue_timeout_ms : Int32
  operation_timeout_ms : Int32
  max_frame_bytes : Int32
  max_in_flight : Int32
  max_in_flight_bytes : Int32
  max_waiting : Int32
  max_waiting_bytes : Int32
  overload_policy : OverloadPolicy
  throw_on_overload : Bool
  compression : Bool
  tls : TlsConfig?
  prepared_cache_capacity : Int32
  max_abandoned : Int32
  abandoned_timeout_ms : Int32
  event_capacity : Int32
  heartbeat_interval_ms : Int32
  heartbeat_timeout_ms : Int32
  metrics : Metrics?
}

///|
/// 构造连接配置，默认操作预算十秒、心跳三十秒；连接前统一校验参数与认证冲突。
pub fn ConnectionBuilder::new(
  host~ : String = "127.0.0.1",
  port~ : Int32 = 9042,
  username? : String,
  password? : String,
  auth_provider? : AuthProvider,
  max_auth_rounds~ : Int32 = 16,
  max_auth_token_bytes~ : Int32 = 65536,
  timeout_ms~ : Int32 = 10000,
  connect_timeout_ms? : Int32,
  queue_timeout_ms? : Int32,
  operation_timeout_ms? : Int32,
  max_frame_bytes~ : Int32 = 16777216,
  max_in_flight~ : Int32 = 128,
  max_in_flight_bytes~ : Int32 = 67108864,
  max_waiting~ : Int32 = 64,
  max_waiting_bytes~ : Int32 = 67108864,
  overload_policy~ : OverloadPolicy = Wait,
  throw_on_overload~ : Bool = false,
  compression~ : Bool = false,
  tls? : TlsConfig,
  prepared_cache_capacity~ : Int32 = 64,
  max_abandoned~ : Int32 = 64,
  abandoned_timeout_ms~ : Int32 = 30000,
  event_capacity~ : Int32 = 256,
  heartbeat_interval_ms~ : Int32 = 30000,
  heartbeat_timeout_ms~ : Int32 = 5000,
  metrics? : Metrics,
) -> ConnectionBuilder {
  {
    host,
    port,
    username,
    password,
    auth_provider,
    max_auth_rounds,
    max_auth_token_bytes,
    timeout_ms,
    connect_timeout_ms: connect_timeout_ms.unwrap_or(timeout_ms),
    queue_timeout_ms: queue_timeout_ms.unwrap_or(timeout_ms),
    operation_timeout_ms: operation_timeout_ms.unwrap_or(timeout_ms),
    max_frame_bytes,
    max_in_flight,
    max_in_flight_bytes,
    max_waiting,
    max_waiting_bytes,
    overload_policy,
    throw_on_overload,
    compression,
    tls,
    prepared_cache_capacity,
    max_abandoned,
    abandoned_timeout_ms,
    event_capacity,
    heartbeat_interval_ms,
    heartbeat_timeout_ms,
    metrics,
  }
}

///|
pub struct Connection {
  socket : Transport
  config : ConnectionBuilder
  response_limits : ResponseLimits
  mut delivery_bytes : Int64
  mut peak_delivery_bytes : Int64
  mut decoded_responses : Int64
  mut discarded_responses : Int64
  mut decode_ms : Int64
  mut max_decode_ms : Int64
  wire : Wire
  mutex : @async.Mutex
  mut closed : Bool
  mut draining : Bool
  mut drain_outcome : DrainOutcome?
  mut active_requests : Int32
  closed_changed : @async.CondVar
  mut failure : Error?
  mut generation : Int32
  mut pool_slot : Int32
  mut rpc_scope : RpcScope
  mut reader_active : Bool
  mut reader_task : @async.Task[Unit]?
  mut reaper_task : @async.Task[Unit]?
  mut health_task : @async.Task[Unit]?
  mut last_received : Int64
  mut abandoned : Int32
  pending : Map[Int32, Pending]
  admission : Admission
  mut next_stream : Int32
  prepared_cache : PreparedCache
  preparing : Map[Bytes, PrepareFlight]
  mut preparing_bytes : Int64
  mut keyspace : String?
  events : @async.Queue[@protocol.ServerEvent]
  mut dropped_events : Int64
}

///|
pub fn Connection::close(self : Connection) -> Unit {
  if !self.closed {
    self.fail(Closed)
  }
}

///|
pub fn Connection::is_closed(self : Connection) -> Bool {
  self.closed
}

///|
pub(all) struct Reply {
  response : @protocol.Response
  warnings : Array[String]
  tracing_id : Bytes?
  custom_payload : Map[String, Bytes?]
  coordinator : Endpoint
  attempt_count : Int32
  previous : Array[ExecutionInfo]
}

///|
async fn Connection::request_internal(
  self : Connection,
  request : @protocol.Request,
  cached : Array[@protocol.Column],
  deadline : Deadline?,
  context : TimeoutContext,
  observation : RequestObservation?,
) -> Reply {
  if self.closed {
    raise Closed
  }
  if self.draining {
    raise Draining
  }
  self.active_requests += 1
  defer {
    self.active_requests -= 1
    self.closed_changed.broadcast()
  }
  if request.body.length() > self.config.max_frame_bytes {
    raise Configuration("request exceeds frame limit")
  }
  let deadline = self.operation_deadline(deadline)
  // 第一次异步等待前登记预算，满载拒绝不会累积计时器和编码缓冲。
  let reservation = self.admission.register(
    request.body.length().to_int64() + 9L,
  )
  defer (if !reservation.owned_by_pending {
    self.admission.release(reservation)
  })
  timed(deadline.remaining_ms(), Operation, context, () => {
    self.exchange(request, cached, context, reservation, observation)
  })
}

///|
async fn Connection::handshake_request(
  self : Connection,
  request : @protocol.Request,
) -> Reply {
  self.wire.send(0, request)
  let frame = self.wire.receive()
  if frame.header.stream != 0 {
    raise Unexpected("response stream mismatch")
  }
  let envelope = @protocol.decode_payload(frame)
  if (frame.header.opcode == 14 || frame.header.opcode == 16) &&
    envelope.message.length() > self.config.max_auth_token_bytes + 4 {
    raise Authentication("authentication token exceeds limit")
  }
  Reply::{
    response: @protocol.decode_response(frame.header.opcode, envelope.message),
    warnings: envelope.warnings,
    tracing_id: envelope.tracing_id,
    custom_payload: envelope.custom_payload,
    coordinator: Endpoint::new(host=self.config.host, port=self.config.port),
    attempt_count: 1,
    previous: [],
  }
}

///|
pub async fn Connection::run(
  self : Connection,
  request : @protocol.Request,
  cached~ : Array[@protocol.Column] = [],
  deadline? : Deadline,
) -> @protocol.ResultSet {
  match self.request(request, cached~, deadline?).response {
    Result(result) => {
      if result is SetKeyspace(name) {
        self.keyspace = Some(name)
        self.prepared_cache.clear()
      }
      result
    }
    Failure(error) => raise Server(error)
    _ => raise Unexpected("expected RESULT response")
  }
}

///|
pub async fn Connection::query(
  self : Connection,
  cql : String,
  values~ : Array[@types.Value] = [],
  options~ : @protocol.QueryOptions = @protocol.QueryOptions::new(),
  deadline? : Deadline,
) -> @protocol.ResultSet {
  let deadline = self.operation_deadline(deadline)
  self.run(@protocol.query(cql, values~, options~), deadline~)
}

///|
async fn[G] connect_internal(
  group : @async.TaskGroup[G],
  config~ : ConnectionBuilder = ConnectionBuilder::new(),
  deadline? : Deadline,
  shared? : Admission,
  response_limits? : ResponseLimits,
) -> Connection {
  config.validate()
  let context = TimeoutContext::{ phase: Connecting, sent: false, }
  let remaining = match deadline {
    Some(deadline) => deadline.remaining_ms()
    None => config.connect_timeout_ms
  }
  let scope = if remaining < config.connect_timeout_ms {
    TimeoutScope::Operation
  } else {
    Connection
  }
  let duration = if remaining < config.connect_timeout_ms {
    remaining
  } else {
    config.connect_timeout_ms
  }
  let mut opened : Connection? = None
  let mut transferred = false
  defer (if !transferred && opened is Some(connection) { connection.close() })
  let connection = timed(duration, scope, context, () => {
    let connection = open_connection(config, parent?=shared, response_limits?)
    opened = Some(connection)
    connection
  })
  connection.reader_active = true
  connection.reader_task = Some(
    group.spawn(() => connection.receive_loop(), no_wait=true),
  )
  connection.reaper_task = Some(
    group.spawn(() => connection.reap_abandoned(), no_wait=true),
  )
  if config.heartbeat_interval_ms > 0 {
    connection.health_task = Some(
      group.spawn(() => connection.maintain_health(), no_wait=true),
    )
  }
  transferred = true
  connection
}

///|
async fn open_connection(
  config : ConnectionBuilder,
  parent? : Admission,
  response_limits? : ResponseLimits,
) -> Connection {
  config.validate()
  let limits = response_limits.unwrap_or_else(() => {
    ResponseLimits::new(max_body_bytes=config.max_frame_bytes)
  })
  let socket = Transport::connect(config)
  let connection = Connection::{
    socket,
    config,
    response_limits: limits,
    delivery_bytes: 0L,
    peak_delivery_bytes: 0L,
    decoded_responses: 0L,
    discarded_responses: 0L,
    decode_ms: 0L,
    max_decode_ms: 0L,
    wire: Wire::new(
      socket,
      if limits.body_bytes < config.max_frame_bytes {
        limits.body_bytes
      } else {
        config.max_frame_bytes
      },
      config.compression,
      config.metrics,
    ),
    mutex: @async.Mutex(),
    closed: false,
    draining: false,
    drain_outcome: None,
    active_requests: 0,
    closed_changed: @async.CondVar::Cond(),
    failure: None,
    generation: 0,
    pool_slot: 0,
    rpc_scope: Data,
    reader_active: false,
    reader_task: None,
    reaper_task: None,
    health_task: None,
    last_received: @async.now(),
    abandoned: 0,
    pending: Map([]),
    admission: Admission::new(config, parent?),
    next_stream: 0,
    prepared_cache: PreparedCache::new(config),
    preparing: Map([]),
    preparing_bytes: 0L,
    keyspace: None,
    events: @async.Queue(kind=Blocking(config.event_capacity)),
    dropped_events: 0L,
  }
  let mut ready = false
  defer (if !ready { connection.close() })
  match connection.handshake_request(@protocol.options()).response {
    Supported(supported) => {
      if !supported.contains("CQL_VERSION") {
        raise Unexpected("server omitted CQL_VERSION")
      }
      if config.compression {
        guard supported.get("COMPRESSION") is Some(methods) &&
          methods.contains("lz4") else {
          raise Configuration("server does not support LZ4 compression")
        }
      }
    }
    Failure(error) => raise Server(error)
    _ => raise Unexpected("expected SUPPORTED")
  }
  match
    connection.handshake_request(
      @protocol.startup(
        compression=config.compression,
        throw_on_overload=config.throw_on_overload,
      ),
    ).response {
    Ready => connection.wire.framed = true
    Authenticate(authenticator) => {
      connection.wire.framed = true
      connection.authenticate(authenticator)
    }
    Failure(error) => raise Server(error)
    _ => raise Unexpected("unexpected STARTUP response")
  }
  ready = true
  connection
}

///|
pub fn Connection::pending_count(self : Connection) -> Int32 {
  self.pending.length()
}

///|
pub fn Connection::abandoned_count(self : Connection) -> Int32 {
  self.abandoned
}

///|
fn ConnectionBuilder::validate(
  self : ConnectionBuilder,
) -> Unit raise DriverError {
  for
    (name, value, minimum, maximum) in [
      ("connect_timeout_ms", self.connect_timeout_ms, 1, 2147483647),
      ("timeout_ms", self.timeout_ms, 1, 2147483647),
      ("queue_timeout_ms", self.queue_timeout_ms, 1, 2147483647),
      ("operation_timeout_ms", self.operation_timeout_ms, 1, 2147483647),
      ("max_frame_bytes", self.max_frame_bytes, 1, 2147483647),
      ("port", self.port, 1, 65535),
      ("max_in_flight", self.max_in_flight, 1, 32768),
      ("max_in_flight_bytes", self.max_in_flight_bytes, 9, 2147483647),
      ("max_waiting", self.max_waiting, 0, 1048576),
      ("max_waiting_bytes", self.max_waiting_bytes, 0, 2147483647),
      ("max_auth_rounds", self.max_auth_rounds, 1, 128),
      ("max_auth_token_bytes", self.max_auth_token_bytes, 0, 16777216),
      ("prepared_cache_capacity", self.prepared_cache_capacity, 0, 65536),
      ("max_abandoned", self.max_abandoned, 0, 32768),
      ("event_capacity", self.event_capacity, 1, 65536),
      ("heartbeat_interval_ms", self.heartbeat_interval_ms, 0, 2147483647),
      ("heartbeat_timeout_ms", self.heartbeat_timeout_ms, 1, 2147483647),
      ("abandoned_timeout_ms", self.abandoned_timeout_ms, 1, 2147483647),
    ] {
    validate_range(name, value, minimum, maximum)
  }
  if self.host.is_empty() {
    raise Configuration("host must be nonempty and contain no NUL")
  }
  for byte in @utf8.encode(self.host) {
    if byte == b'\x00' {
      raise Configuration("host must contain no NUL")
    }
  }
  if self.tls is Some(options) {
    validate_tls_name(options.server_name.unwrap_or(self.host))
    if options.ca_file is Some(path) {
      validate_tls_name(path)
    }
    match options.identity {
      Some(Pem(certificate, private_key)) => {
        validate_tls_name(certificate)
        validate_tls_name(private_key)
      }
      Some(WindowsStore(thumbprint)) => validate_tls_name(thumbprint)
      None => ()
    }
  }
  if (self.username is None) != (self.password is None) {
    raise Configuration("username and password must be supplied together")
  }
  if self.auth_provider is Some(_) && self.username is Some(_) {
    raise Configuration("use either auth_provider or username/password")
  }
}

///|
fn validate_range(
  name : String,
  value : Int32,
  minimum : Int32,
  maximum : Int32,
) -> Unit raise DriverError {
  if value < minimum || value > maximum {
    raise Configuration("\{name} must be \{minimum}..\{maximum}")
  }
}

///|
async fn Connection::wait_closed(self : Connection) -> Unit {
  while !self.closed {
    self.closed_changed.wait()
  }
}

///|
pub async fn Connection::shutdown(self : Connection) -> Unit {
  self.close()
  if self.reader_task is Some(task) {
    ignore(task.wait()) catch {
      _ => ()
    }
  }
  if self.reaper_task is Some(task) {
    ignore(task.wait()) catch {
      _ => ()
    }
  }
  self.reader_task = None
  self.reaper_task = None
  if self.health_task is Some(task) {
    ignore(task.wait()) catch {
      _ => ()
    }
  }
  self.health_task = None
  while self.active_requests > 0 {
    self.closed_changed.wait()
  }
}
