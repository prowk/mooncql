///|
fn endpoint_config(
  base : Config,
  endpoint : Endpoint,
) -> Config raise DriverError {
  let tls = match base.tls {
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
  let connection = { ..base, host: endpoint.host, port: endpoint.port, tls, }
  connection.validate()
  connection
}

///|
fn session_node(
  base : Config,
  endpoint : Endpoint,
) -> SessionNode raise DriverError {
  {
    endpoint,
    config: endpoint_config(base, endpoint),
    current: None,
    worker: None,
    state: Connecting,
    generation: 0,
    attempts: 0,
    last_error: None,
  }
}

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
} derive(@debug.Debug)

///|
pub extend Endpoint with @debug.Debug::{to_repr}

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
  routing : RoutingConfig?
  discovery : DiscoveryConfig?
}

///|
pub fn SessionConfig::new(
  connection? : Config = Config::new(),
  contact_points? : Array[Endpoint] = [],
  backoff_initial_ms? : Int = 25,
  backoff_max_ms? : Int = 2000,
  jitter? : Double = 0.2,
  stable_reset_ms? : Int = 1000,
  discovery? : DiscoveryConfig,
  routing? : RoutingConfig,
) -> SessionConfig {
  {
    connection,
    contact_points: contact_points.copy(),
    backoff_initial_ms,
    backoff_max_ms,
    jitter,
    stable_reset_ms,
    discovery,
    routing,
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
  mut draining : Bool
  mut drain_outcome : DrainOutcome?
  mut generation : Int
  mut next_node : Int
  mut last_error : Error?
  mut active : Int
  mut waiting : Int
  mut waiting_bytes : Int64
  control : ControlState?
}

///|
pub async fn[T] with_session(
  config? : SessionConfig = SessionConfig::new(),
  body : async (Session) -> T,
) -> T {
  let config = { ..config, contact_points: config.contact_points.copy(), }
  config.connection.validate()
  if config.routing is Some(routing) &&
    (
      config.discovery is None ||
      routing.local_dc.is_empty() ||
      routing.max_metadata_age_ms < 1
    ) {
    raise Configuration(
      "routing requires discovery, local_dc and positive metadata age",
    )
  }
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
    session_node(config.connection, endpoint)
  })
  let control = config.discovery.map(discovery => {
    if discovery.refresh_interval_ms < 1 ||
      discovery.debounce_ms < 0 ||
      discovery.debounce_ms > 60000 ||
      discovery.max_nodes < 1 ||
      discovery.max_nodes > 65536 ||
      discovery.max_tokens_per_node < 1 ||
      discovery.max_tokens_per_node > 65536 ||
      discovery.max_keyspaces < 1 ||
      discovery.max_keyspaces > 65536 {
      raise Configuration("invalid discovery limits")
    }
    ControlState::{
      config: discovery,
      worker: None,
      connection: None,
      snapshot: None,
      stale: true,
      generation: 0,
      refreshes: 0,
      last_error: None,
      ring: None,
      locations: Map([]),
    }
  })
  @async.with_task_group(group => {
    let session = Session::{
      config,
      changed: @async.CondVar::Cond(),
      nodes,
      closed: false,
      draining: false,
      drain_outcome: None,
      generation: 0,
      next_node: 0,
      last_error: None,
      active: 0,
      waiting: 0,
      waiting_bytes: 0L,
      control,
    }
    defer session.stop()
    for node in nodes {
      node.worker = Some(
        group.spawn(() => session.maintain(node, group), no_wait=true),
      )
    }
    if control is Some(control) {
      control.worker = Some(
        group.spawn(
          () => session.maintain_control(control, group),
          no_wait=true,
        ),
      )
    }
    body(session)
  })
}

///|
fn Session::stop(self : Session) -> Unit {
  if !self.closed {
    if self.draining && self.drain_outcome is None {
      self.drain_outcome = Some(Interrupted(self.active))
    }
    self.closed = true
    if self.control is Some(control) {
      if control.connection is Some(connection) {
        connection.close()
      }
      if control.worker is Some(worker) {
        worker.cancel()
      }
    }
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
  if self.control is Some(control) {
    if control.worker is Some(worker) {
      ignore(worker.wait()) catch {
        _ => ()
      }
    }
    control.worker = None
  }
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
  while !self.closed && !self.draining {
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
        if node.generation > 1 &&
          self.config.connection.metrics is Some(metrics) {
          metrics.data.reconnects += 1L
          metrics.emit(Reconnected(node.endpoint, node.generation, false))
        }
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
    if self.closed || self.draining {
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
fn Session::choose(
  self : Session,
  hint : RoutingHint?,
  attempted : Array[String],
) -> Connection? {
  let indices = self.plan_indices(hint, attempted)
  if indices.is_empty() {
    return None
  }
  let index = indices[0]
  self.next_node = (index + 1) % self.nodes.length()
  self.nodes[index].current
}

///|
async fn Session::select(
  self : Session,
  deadline : Deadline,
  bytes : Int64,
  hint? : RoutingHint,
  attempted? : Array[String] = [],
) -> Connection {
  if self.closed {
    raise Closed
  }
  if self.choose(hint, attempted) is Some(connection) {
    return connection
  }
  let observation = match self.config.connection.metrics {
    Some(metrics) => Some(WaitObservation::new(metrics, Connection, bytes))
    None => None
  }
  defer (if observation is Some(observation) { observation.finish() })
  let outcome = Ok(self.wait_connection(deadline, bytes, hint, attempted)) catch {
    error => Err(error)
  }
  match outcome {
    Ok(connection) => {
      if observation is Some(observation) {
        observation.outcome = Succeeded
      }
      connection
    }
    Err(error) => {
      if observation is Some(observation) {
        observation.outcome = request_outcome(error)
      }
      raise error
    }
  }
}

///|
async fn Session::wait_connection(
  self : Session,
  deadline : Deadline,
  bytes : Int64,
  hint : RoutingHint?,
  attempted : Array[String],
) -> Connection {
  if self.waiting >= self.config.connection.max_waiting {
    raise Overloaded(WaitingQueueFull)
  }
  if self.waiting_bytes + bytes >
    self.config.connection.max_waiting_bytes.to_int64() {
    raise Overloaded(WaitingBytesFull)
  }
  self.waiting += 1
  self.waiting_bytes += bytes
  if self.config.connection.metrics is Some(metrics) {
    metrics.gauges(0L, 0L, 1L, bytes)
  }
  defer {
    self.waiting -= 1
    self.waiting_bytes -= bytes
    if self.config.connection.metrics is Some(metrics) {
      metrics.gauges(0L, 0L, -1L, -bytes)
    }
    self.changed.broadcast()
  }
  timed(
    deadline.remaining_ms(),
    Operation,
    { phase: WaitingConnection, sent: false, },
    () => {
      while !self.closed {
        if self.choose(hint, attempted) is Some(connection) {
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
  idempotent? : Bool = false,
  retry? : RetryPolicy = RetryPolicy::new(),
  routing? : RoutingHint,
) -> Reply {
  let deadline = self.operation_deadline(deadline)
  if request.body.length() > self.config.connection.max_frame_bytes {
    raise Configuration("request exceeds frame limit")
  }
  self.begin_operation()
  defer {
    self.active -= 1
    self.changed.broadcast()
  }
  let enabled = idempotent && (request.opcode == 7 || request.opcode == 10)
  self.execute_retry(
    deadline,
    request.body.length().to_int64() + 9L,
    enabled,
    retry,
    routing,
    connection => {
      let reply = connection.request(request, deadline~)
      if enabled && retry.max_attempts > 1 && reply.response is Failure(error) {
        raise ExecutionError(Server(error), reply.execution_info())
      }
      reply
    },
    complete=(reply, failures) => {
      let previous = []
      for failure in failures {
        if failure.execution_info is Some(info) {
          previous.push(info)
        }
      }
      { ..reply, attempt_count: failures.length() + 1, previous, }
    },
  )
}

///|
pub async fn Session::query(
  self : Session,
  cql : String,
  values? : Array[@types.Value] = [],
  options? : @protocol.QueryOptions = @protocol.QueryOptions::new(),
  deadline? : Deadline,
  idempotent? : Bool = false,
  retry? : RetryPolicy = RetryPolicy::new(),
  routing? : RoutingHint,
) -> @protocol.ResultSet {
  let deadline = self.operation_deadline(deadline)
  match
    self.request(
      @protocol.query(cql, values~, options~),
      deadline~,
      idempotent~,
      retry~,
      routing?,
    ).response {
    Result(result) => result
    Failure(error) => raise Server(error)
    _ => raise Unexpected("expected RESULT response")
  }
}
