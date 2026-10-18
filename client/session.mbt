///|
pub(all) enum NodeState {
  Connecting
  Ready
  Backoff
  Stopped
} derive(Eq, @debug.Debug)

///|
pub extend NodeState with Eq::{equal, not_equal}

///|
pub extend NodeState with @debug.Debug::{to_repr}

///|
pub(all) struct Endpoint {
  host : String
  port : Int
  server_name : String?
}

///|
pub fn Endpoint::new(
  host? : String = "127.0.0.1",
  port? : Int = 9042,
  server_name? : String,
) -> Endpoint {
  { host, port, server_name, }
}

///|
pub(all) struct SessionConfig {
  connection : Config
  contact_points : Array[Endpoint]
  backoff_initial_ms : Int
  backoff_max_ms : Int
  jitter : Double
  stable_reset_ms : Int
}

///|
pub fn SessionConfig::new(
  connection? : Config = Config::new(),
  contact_points? : Array[Endpoint] = [],
  backoff_initial_ms? : Int = 25,
  backoff_max_ms? : Int = 2000,
  jitter? : Double = 0.2,
  stable_reset_ms? : Int = 1000,
) -> SessionConfig {
  {
    connection,
    contact_points: contact_points.copy(),
    backoff_initial_ms,
    backoff_max_ms,
    jitter,
    stable_reset_ms,
  }
}

///|
pub(all) struct NodeStatus {
  state : NodeState
  generation : Int
  attempts : Int
}

///|
pub(all) struct NodeInfo {
  endpoint : Endpoint
  status : NodeStatus
  last_error : Error?
}

///|
struct SessionNode {
  endpoint : Endpoint
  config : Config
  mut current : Connection?
  mut worker : @async.Task[Unit]?
  mut state : NodeState
  mut generation : Int
  mut attempts : Int
  mut last_error : Error?
}

///|
pub struct Session {
  config : SessionConfig
  changed : @async.CondVar
  nodes : Array[SessionNode]
  mut closed : Bool
  mut generation : Int
  mut next_node : Int
  mut last_error : Error?
  mut active : Int
  mut waiting : Int
  mut waiting_bytes : Int64
}

///|
pub async fn[T] with_session(
  config? : SessionConfig = SessionConfig::new(),
  body : async (Session) -> T,
) -> T {
  config.connection.validate()
  if config.backoff_initial_ms < 1 ||
    config.backoff_max_ms < config.backoff_initial_ms ||
    config.stable_reset_ms < 0 ||
    !(config.jitter >= 0.0 && config.jitter <= 1.0) {
    raise Configuration("invalid session backoff configuration")
  }
  let endpoints = if config.contact_points.is_empty() {
    [Endpoint::new(host=config.connection.host, port=config.connection.port)]
  } else {
    config.contact_points.copy()
  }
  let seen : Map[String, Bool] = Map([])
  let nodes = endpoints.map(endpoint => {
    let key = "\{endpoint.host}:\{endpoint.port}"
    if seen.contains(key) {
      raise Configuration("duplicate contact point")
    }
    seen[key] = true
    let tls = match config.connection.tls {
      Some(tls) =>
        Some({
          ..tls,
          server_name: if endpoint.server_name is Some(_) {
            endpoint.server_name
          } else {
            tls.server_name
          },
        })
      None => {
        if endpoint.server_name is Some(_) {
          raise Configuration("endpoint server name requires TLS")
        }
        None
      }
    }
    let connection = {
      ..config.connection,
      host: endpoint.host,
      port: endpoint.port,
      tls,
    }
    connection.validate()
    SessionNode::{
      endpoint,
      config: connection,
      current: None,
      worker: None,
      state: Connecting,
      generation: 0,
      attempts: 0,
      last_error: None,
    }
  })
  @async.with_task_group(group => {
    let session = Session::{
      config,
      changed: @async.CondVar::Cond(),
      nodes,
      closed: false,
      generation: 0,
      next_node: 0,
      last_error: None,
      active: 0,
      waiting: 0,
      waiting_bytes: 0L,
    }
    defer session.stop()
    for node in nodes {
      node.worker = Some(
        group.spawn(() => session.maintain(node, group), no_wait=true),
      )
    }
    body(session)
  })
}

///|
fn Session::stop(self : Session) -> Unit {
  if !self.closed {
    self.closed = true
    for node in self.nodes {
      if node.current is Some(connection) {
        connection.close()
      }
      if node.worker is Some(task) {
        task.cancel()
      }
    }
    self.changed.broadcast()
  }
}

///|
pub async fn Session::close(self : Session) -> Unit {
  self.stop()
  for node in self.nodes {
    if node.worker is Some(task) {
      ignore(task.wait()) catch {
        _ => ()
      }
    }
    node.worker = None
  }
  while self.active > 0 {
    self.changed.wait()
  }
}

///|
pub fn Session::is_closed(self : Session) -> Bool {
  self.closed
}

///|
pub fn Session::status(self : Session) -> NodeStatus {
  let mut state = if self.closed { NodeState::Stopped } else { Backoff }
  let mut attempts = 0
  for node in self.nodes {
    attempts += node.attempts
    if !self.closed {
      if node.current is Some(connection) && !connection.is_closed() {
        state = Ready
      } else if state != Ready && node.state == Connecting {
        state = Connecting
      }
    }
  }
  { state, generation: self.generation, attempts, }
}

///|
pub fn Session::nodes(self : Session) -> Array[NodeInfo] {
  self.nodes.map(node => {
    endpoint: node.endpoint,
    status: {
      state: node.state,
      generation: node.generation,
      attempts: node.attempts,
    },
    last_error: node.last_error,
  })
}

///|
pub fn Session::last_error(self : Session) -> Error? {
  self.last_error
}

///|
pub fn Session::waiting_count(self : Session) -> Int {
  self.waiting
}

///|
pub fn Session::active_count(self : Session) -> Int {
  self.active
}

///|
async fn[G] Session::maintain(
  self : Session,
  node : SessionNode,
  group : @async.TaskGroup[G],
) -> Unit {
  defer {
    node.state = Stopped
    self.changed.broadcast()
  }
  let random = @random.Rand::new()
  let mut backoff = self.config.backoff_initial_ms
  while !self.closed {
    node.state = Connecting
    node.attempts += 1
    self.changed.broadcast()
    let connection = Some(connect(group, config=node.config)) catch {
      error => {
        node.last_error = Some(error)
        self.last_error = Some(error)
        None
      }
    }
    if connection is Some(connection) {
      let since = @async.now()
      {
        node.current = Some(connection)
        node.generation += 1
        self.generation += 1
        connection.generation = node.generation
        node.state = Ready
        node.last_error = None
        self.last_error = None
        self.changed.broadcast()
        // 一个节点的收尾仅处理自己的连接，其他节点继续服务。
        defer @async.protect_from_cancel(() => {
          connection.shutdown()
          node.current = None
          self.changed.broadcast()
        })
        connection.wait_closed()
        node.last_error = connection.failure
        self.last_error = connection.failure
      }
      if @async.now() - since >= self.config.stable_reset_ms.to_int64() {
        backoff = self.config.backoff_initial_ms
      }
    }
    if self.closed {
      return
    }
    node.state = Backoff
    self.changed.broadcast()
    let candidate = backoff.to_double() *
      (1.0 - self.config.jitter + 2.0 * self.config.jitter * random.double())
    let delay = if candidate < 1.0 {
      1
    } else if candidate > self.config.backoff_max_ms.to_double() {
      self.config.backoff_max_ms
    } else {
      candidate.to_int()
    }
    @async.sleep(delay)
    backoff = if backoff > self.config.backoff_max_ms / 2 {
      self.config.backoff_max_ms
    } else {
      backoff * 2
    }
  }
}

///|
fn Session::choose(self : Session) -> Connection? {
  if self.nodes.is_empty() {
    return None
  }
  for offset in 0..<self.nodes.length() {
    let index = (self.next_node + offset) % self.nodes.length()
    if self.nodes[index].current is Some(connection) && !connection.is_closed() {
      self.next_node = (index + 1) % self.nodes.length()
      return Some(connection)
    }
  }
  None
}

///|
async fn Session::select(
  self : Session,
  deadline : Deadline,
  bytes : Int64,
) -> Connection {
  if self.closed {
    raise Closed
  }
  if self.choose() is Some(connection) {
    return connection
  }
  if self.waiting >= self.config.connection.max_waiting {
    raise Overloaded(WaitingQueueFull)
  }
  if self.waiting_bytes + bytes >
    self.config.connection.max_waiting_bytes.to_int64() {
    raise Overloaded(WaitingBytesFull)
  }
  self.waiting += 1
  self.waiting_bytes += bytes
  defer {
    self.waiting -= 1
    self.waiting_bytes -= bytes
    self.changed.broadcast()
  }
  timed(
    deadline.remaining_ms(),
    Operation,
    { phase: WaitingConnection, sent: false, },
    () => {
      while !self.closed {
        if self.choose() is Some(connection) {
          return connection
        }
        self.changed.wait()
      }
      raise Closed
    },
  )
}

///|
fn Session::operation_deadline(
  self : Session,
  deadline : Deadline?,
) -> Deadline raise DriverError {
  match deadline {
    Some(deadline) => deadline
    None => Deadline::after(self.config.connection.operation_timeout_ms)
  }
}

///|
pub async fn Session::request(
  self : Session,
  request : @protocol.Request,
  deadline? : Deadline,
) -> Reply {
  let deadline = self.operation_deadline(deadline)
  if request.body.length() > self.config.connection.max_frame_bytes {
    raise Configuration("request exceeds frame limit")
  }
  self.active += 1
  defer {
    self.active -= 1
    self.changed.broadcast()
  }
  let connection = self.select(deadline, request.body.length().to_int64() + 9L)
  // 只选择一次连接；断线失败直接交给调用方，不重新执行未知结果的请求。
  connection.request(request, deadline~)
}

///|
pub async fn Session::query(
  self : Session,
  cql : String,
  values? : Array[@types.Value] = [],
  options? : @protocol.QueryOptions = @protocol.QueryOptions::new(),
  deadline? : Deadline,
) -> @protocol.ResultSet {
  let deadline = self.operation_deadline(deadline)
  match
    self.request(@protocol.query(cql, values~, options~), deadline~).response {
    Result(result) => result
    Failure(error) => raise Server(error)
    _ => raise Unexpected("expected RESULT response")
  }
}
