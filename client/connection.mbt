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
} derive(@debug.Debug)

///|
pub extend DriverError with @debug.Debug::{to_repr}

///|
pub(all) struct Config {
  host : String
  port : Int
  username : String?
  password : String?
  timeout_ms : Int
  connect_timeout_ms : Int
  queue_timeout_ms : Int
  operation_timeout_ms : Int
  max_frame_bytes : Int
  max_in_flight : Int
  max_in_flight_bytes : Int
  max_waiting : Int
  max_waiting_bytes : Int
  overload_policy : OverloadPolicy
  throw_on_overload : Bool
  compression : Bool
  tls : TlsConfig?
  prepared_cache_capacity : Int
  max_abandoned : Int
  abandoned_timeout_ms : Int
  event_capacity : Int
}

///|
pub fn Config::new(
  host? : String = "127.0.0.1",
  port? : Int = 9042,
  username? : String,
  password? : String,
  timeout_ms? : Int = 10000,
  connect_timeout_ms? : Int,
  queue_timeout_ms? : Int,
  operation_timeout_ms? : Int,
  max_frame_bytes? : Int = 16777216,
  max_in_flight? : Int = 128,
  max_in_flight_bytes? : Int = 67108864,
  max_waiting? : Int = 64,
  max_waiting_bytes? : Int = 67108864,
  overload_policy? : OverloadPolicy = Wait,
  throw_on_overload? : Bool = false,
  compression? : Bool = false,
  tls? : TlsConfig,
  prepared_cache_capacity? : Int = 64,
  max_abandoned? : Int = 64,
  abandoned_timeout_ms? : Int = 30000,
  event_capacity? : Int = 256,
) -> Config {
  {
    host,
    port,
    username,
    password,
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
  }
}

///|
pub struct Connection {
  socket : Transport
  config : Config
  wire : Wire
  mutex : @async.Mutex
  mut closed : Bool
  closed_changed : @async.CondVar
  mut failure : Error?
  mut generation : Int
  mut reader_active : Bool
  mut reader_task : @async.Task[Unit]?
  mut reaper_task : @async.Task[Unit]?
  mut abandoned : Int
  pending : Map[Int, Pending]
  admission : Admission
  mut next_stream : Int
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
}

///|
pub async fn Connection::request(
  self : Connection,
  request : @protocol.Request,
  cached? : Array[@protocol.Column] = [],
  deadline? : Deadline,
) -> Reply {
  if self.closed {
    raise Closed
  }
  if request.body.length() > self.config.max_frame_bytes {
    raise Configuration("request exceeds frame limit")
  }
  let deadline = self.operation_deadline(deadline)
  let context = TimeoutContext::{ phase: WaitingSlot, sent: false, }
  // 第一次异步等待前登记预算，满载拒绝不会累积计时器和编码缓冲。
  let reservation = self.admission.register(
    request.body.length().to_int64() + 9L,
  )
  defer (if !reservation.owned_by_pending {
    self.admission.release(reservation)
  })
  timed(deadline.remaining_ms(), Operation, context, () => {
    self.exchange(request, cached, context, reservation)
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
  Reply::{
    response: @protocol.decode_response(frame.header.opcode, envelope.message),
    warnings: envelope.warnings,
    tracing_id: envelope.tracing_id,
    custom_payload: envelope.custom_payload,
  }
}

///|
pub async fn Connection::run(
  self : Connection,
  request : @protocol.Request,
  cached? : Array[@protocol.Column] = [],
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
  values? : Array[@types.Value] = [],
  options? : @protocol.QueryOptions = @protocol.QueryOptions::new(),
  deadline? : Deadline,
) -> @protocol.ResultSet {
  let deadline = self.operation_deadline(deadline)
  self.run(@protocol.query(cql, values~, options~), deadline~)
}

///|
pub async fn[G] connect(
  group : @async.TaskGroup[G],
  config? : Config = Config::new(),
  deadline? : Deadline,
) -> Connection {
  if config.connect_timeout_ms <= 0 {
    raise Configuration("invalid connection timeout")
  }
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
    let connection = open_connection(config)
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
  transferred = true
  connection
}

///|
async fn open_connection(config : Config) -> Connection {
  config.validate()
  let socket = Transport::connect(config)
  let connection = Connection::{
    socket,
    config,
    wire: Wire::new(socket, config.max_frame_bytes, config.compression),
    mutex: @async.Mutex(),
    closed: false,
    closed_changed: @async.CondVar::Cond(),
    failure: None,
    generation: 0,
    reader_active: false,
    reader_task: None,
    reaper_task: None,
    abandoned: 0,
    pending: Map([]),
    admission: Admission::new(config),
    next_stream: 0,
    prepared_cache: PreparedCache::new(config.prepared_cache_capacity),
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
      if authenticator != "org.apache.cassandra.auth.PasswordAuthenticator" {
        raise Authentication("unsupported server authenticator")
      }
      guard config.username is Some(username) else {
        raise Authentication("server requires credentials")
      }
      guard config.password is Some(password) else {
        raise Authentication("server requires password")
      }
      match
        connection.handshake_request(
          @protocol.password_auth(username, password),
        ).response {
        AuthSuccess(_) => ()
        Failure(error) => raise Server(error)
        _ => raise Authentication("unexpected authentication response")
      }
    }
    Failure(error) => raise Server(error)
    _ => raise Unexpected("unexpected STARTUP response")
  }
  ready = true
  connection
}

///|
pub fn Connection::pending_count(self : Connection) -> Int {
  self.pending.length()
}

///|
pub fn Connection::abandoned_count(self : Connection) -> Int {
  self.abandoned
}

///|
fn Config::validate(self : Config) -> Unit raise DriverError {
  if self.connect_timeout_ms <= 0 {
    raise Configuration("invalid connection timeout")
  }
  if self.timeout_ms <= 0 ||
    self.queue_timeout_ms <= 0 ||
    self.operation_timeout_ms <= 0 ||
    self.max_frame_bytes <= 0 ||
    self.port <= 0 ||
    self.port > 65535 ||
    self.max_in_flight < 1 ||
    self.max_in_flight > 32768 ||
    self.max_in_flight_bytes < 9 ||
    self.max_waiting < 0 ||
    self.max_waiting_bytes < 0 ||
    self.prepared_cache_capacity < 0 ||
    self.prepared_cache_capacity > 65536 ||
    self.max_abandoned < 0 ||
    self.max_abandoned > 32768 ||
    self.event_capacity < 1 ||
    self.event_capacity > 65536 ||
    self.abandoned_timeout_ms <= 0 {
    raise Configuration("invalid timeout, frame limit or port")
  }
  if (self.username is None) != (self.password is None) {
    raise Configuration("username and password must be supplied together")
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
}
