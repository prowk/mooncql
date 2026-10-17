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
}

///|
pub fn Config::new(
  host? : String = "127.0.0.1",
  port? : Int = 9042,
  username? : String,
  password? : String,
  timeout_ms? : Int = 10000,
  max_frame_bytes? : Int = 16777216,
) -> Config {
  { host, port, username, password, timeout_ms, max_frame_bytes, }
}

///|
pub struct Connection {
  socket : @socket.Tcp
  config : Config
  mutex : @async.Mutex
  mut closed : Bool
}

///|
pub fn Connection::close(self : Connection) -> Unit {
  if !self.closed {
    self.closed = true
    self.socket.close()
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
async fn read_frame(
  socket : @socket.Tcp,
  max_frame_bytes : Int,
) -> @protocol.Frame {
  let header = @protocol.decode_header(
    socket.read_exactly(9),
    max_body=max_frame_bytes,
  )
  if !header.response {
    raise Unexpected("server sent request frame")
  }
  { header, body: socket.read_exactly(header.length), }
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
      if request.body.length() > self.config.max_frame_bytes {
        raise Unexpected("request exceeds frame limit")
      }
      self.socket.write(@protocol.encode_frame(0, request.opcode, request.body))
      let frame = read_frame(self.socket, self.config.max_frame_bytes)
      if frame.header.stream != 0 {
        raise Unexpected("response stream mismatch")
      }
      let envelope = @protocol.decode_envelope(frame)
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
    Result(result) => result
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
    config.port > 65535 {
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
    mutex: @async.Mutex(),
    closed: false,
  }
  let mut ready = false
  defer (if !ready { connection.close() })
  match connection.request(@protocol.options()).response {
    Supported(supported) =>
      if !supported.contains("CQL_VERSION") {
        raise Unexpected("server omitted CQL_VERSION")
      }
    Failure(error) => raise Server(error)
    _ => raise Unexpected("expected SUPPORTED")
  }
  match connection.request(@protocol.startup()).response {
    Ready => ()
    Authenticate(authenticator) => {
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
