///|
pub(all) suberror DriverError {
  Closed
  Unexpected(String)
  Authentication(String)
  Server(@protocol.ServerError)
  RequestTimedOut
  Configuration(String)
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
  max_frame_bytes : Int
  max_in_flight : Int
  compression : Bool
}

///|
pub fn Config::new(
  host? : String = "127.0.0.1",
  port? : Int = 9042,
  username? : String,
  password? : String,
  timeout_ms? : Int = 10000,
  max_frame_bytes? : Int = 16777216,
  max_in_flight? : Int = 128,
  compression? : Bool = false,
) -> Config {
  {
    host,
    port,
    username,
    password,
    timeout_ms,
    max_frame_bytes,
    max_in_flight,
    compression,
  }
}

///|
pub struct Connection {
  socket : @socket.Tcp
  config : Config
  wire : Wire
  mutex : @async.Mutex
  mut closed : Bool
  mut reader_active : Bool
  mut reader_task : @async.Task[Unit]?
  pending : Map[Int, Pending]
  slots : @async.Semaphore
  mut next_stream : Int
  prepared_cache : Map[Bytes, Prepared]
  prepare_mutex : @async.Mutex
  mut keyspace : String?
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
) -> Reply {
  if self.closed {
    raise Closed
  }
  if request.body.length() > self.config.max_frame_bytes {
    raise Configuration("request exceeds frame limit")
  }
  if self.reader_active {
    return @async.with_timeout(self.config.timeout_ms, error=RequestTimedOut, () => {
      self.exchange(request, cached)
    })
  }
  self.mutex.acquire()
  defer self.mutex.release()
  if self.closed {
    raise Closed
  }
  let mut completed = false
  // 超时或取消可能发生在半帧读写中，关闭连接避免后续请求错配。
  defer (if !completed { self.close() })
  let reply = @async.with_timeout(
    self.config.timeout_ms,
    error=RequestTimedOut,
    () => {
      self.wire.send(0, request)
      let frame = self.wire.receive()
      if frame.header.stream != 0 {
        raise Unexpected("response stream mismatch")
      }
      let envelope = @protocol.decode_payload(frame)
      let response = @protocol.decode_response(
        frame.header.opcode,
        envelope.message,
        cached~,
      )
      Reply::{
        response,
        warnings: envelope.warnings,
        tracing_id: envelope.tracing_id,
        custom_payload: envelope.custom_payload,
      }
    },
  )
  completed = true
  reply
}

///|
pub async fn Connection::run(
  self : Connection,
  request : @protocol.Request,
  cached? : Array[@protocol.Column] = [],
) -> @protocol.ResultSet {
  match self.request(request, cached~).response {
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
) -> @protocol.ResultSet {
  self.run(@protocol.query(cql, values~, options~))
}

///|
pub async fn connect(config? : Config = Config::new()) -> Connection {
  if config.timeout_ms <= 0 ||
    config.max_frame_bytes <= 0 ||
    config.port <= 0 ||
    config.port > 65535 ||
    config.max_in_flight < 1 ||
    config.max_in_flight > 32768 {
    raise Configuration("invalid timeout, frame limit or port")
  }
  if (config.username is None) != (config.password is None) {
    raise Configuration("username and password must be supplied together")
  }
  let socket = @async.with_timeout(config.timeout_ms, error=RequestTimedOut, () => {
    @socket.Tcp::connect_to_host(config.host, port=config.port)
  })
  let connection = Connection::{
    socket,
    config,
    wire: Wire::new(socket, config.max_frame_bytes, config.compression),
    mutex: @async.Mutex(),
    closed: false,
    reader_active: false,
    reader_task: None,
    pending: Map([]),
    slots: @async.Semaphore(config.max_in_flight),
    next_stream: 0,
    prepared_cache: Map([]),
    prepare_mutex: @async.Mutex(),
    keyspace: None,
  }
  let mut ready = false
  defer (if !ready { connection.close() })
  match connection.request(@protocol.options()).response {
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
    connection.request(@protocol.startup(compression=config.compression)).response {
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
        connection.request(@protocol.password_auth(username, password)).response {
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
