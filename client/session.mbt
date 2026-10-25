///|
fn endpoint_config(
  base : ConnectionBuilder,
  endpoint : Endpoint,
) -> ConnectionBuilder raise DriverError {
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
  base : ConnectionBuilder,
  endpoint : Endpoint,
  connections_per_node : Int,
) -> SessionNode raise DriverError {
  {
    endpoint,
    config: endpoint_config(base, endpoint),
    slots: Array::makei(connections_per_node, index => PoolSlot::new(index)),
    next_slot: 0,
    connect_gate: @async.Mutex(),
    connecting: 0,
    host_id: None,
    worker: None,
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
pub(all) struct SessionBuilder {
  enforce_limits : Bool
  connection : ConnectionBuilder
  contact_points : Array[Endpoint]
  backoff_initial_ms : Int
  backoff_max_ms : Int
  jitter : Double
  stable_reset_ms : Int
  routing : RoutingConfig?
  discovery : DiscoveryConfig?
  schema_agreement : SchemaAgreementConfig
  execution_profile : ExecutionProfile?
  limits : SessionLimits
  connections_per_node : Int
}

///|
/// 默认每节点单连接并共享固定 limits；发现与 DDL 后等待须显式启用。
pub fn SessionBuilder::new(
  connection? : ConnectionBuilder = ConnectionBuilder::new(),
  contact_points? : Array[Endpoint] = [],
  backoff_initial_ms? : Int = 25,
  backoff_max_ms? : Int = 2000,
  jitter? : Double = 0.2,
  stable_reset_ms? : Int = 1000,
  discovery? : DiscoveryConfig,
  routing? : RoutingConfig,
  schema_agreement? : SchemaAgreementConfig = SchemaAgreementConfig::new(),
  execution_profile? : ExecutionProfile,
  limits? : SessionLimits = SessionLimits::new(),
  connections_per_node? : Int = 1,
) -> SessionBuilder {
  {
    enforce_limits: true,
    connection,
    contact_points: contact_points.copy(),
    backoff_initial_ms,
    backoff_max_ms,
    jitter,
    stable_reset_ms,
    discovery,
    routing,
    schema_agreement,
    execution_profile,
    limits,
    connections_per_node,
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
  config : ConnectionBuilder
  slots : Array[PoolSlot]
  mut next_slot : Int
  connect_gate : @async.Mutex
  mut connecting : Int
  mut host_id : Bytes?
  mut worker : @async.Task[Unit]?
  mut generation : Int
  mut attempts : Int
  mut last_error : Error?
}

///|
pub struct Session {
  config : SessionBuilder
  response_limits : ResponseLimits?
  retry_random : @random.Rand
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
  schema_cache : SchemaCache
  admission : Admission
}

///|
pub async fn[T] with_session_builder(
  config? : SessionBuilder = SessionBuilder::new(),
  response_limits? : ResponseLimits,
  body : async (Session) -> T,
) -> T {
  config.validate()
  let config = { ..config, contact_points: config.contact_points.copy(), }
  let endpoints = if config.contact_points.is_empty() {
    [Endpoint::new(host=config.connection.host, port=config.connection.port)]
  } else {
    config.contact_points.copy()
  }
  let seen : Map[String, Bool] = Map([])
  let nodes = endpoints.map(endpoint => {
    let key = "\{endpoint.host}:\{endpoint.port}"
    if seen.contains(key) {
      raise Configuration("contact_points must be unique by host and port")
    }
    seen[key] = true
    session_node(config.connection, endpoint, config.connections_per_node)
  })
  let control = config.discovery.map(discovery => ControlState::{
    config: discovery,
    worker: None,
    connection: None,
    snapshot: None,
    stale: true,
    generation: 0,
    refreshes: 0,
    schema_epoch: 0,
    last_error: None,
    ring: None,
    locations: Map([]),
  })
  @async.with_task_group(group => {
    let changed = @async.CondVar::Cond()
    let admission = Admission::new(
      config.limits.as_config(config.connection),
      changed~,
      session=true,
      enforce=config.enforce_limits,
    )
    let session = Session::{
      config,
      response_limits,
      retry_random: @random.Rand::new(),
      changed,
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
      schema_cache: SchemaCache::new(),
      admission,
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
fn SessionBuilder::validate(self : SessionBuilder) -> Unit raise DriverError {
  self.connection.validate()
  self.schema_agreement.validate()
  self.limits.validate()
  validate_range("connections_per_node", self.connections_per_node, 1, 8)
  validate_range("backoff_initial_ms", self.backoff_initial_ms, 1, 2147483647)
  validate_range(
    "backoff_max_ms",
    self.backoff_max_ms,
    self.backoff_initial_ms,
    2147483647,
  )
  validate_range("stable_reset_ms", self.stable_reset_ms, 0, 2147483647)
  if !(self.jitter >= 0.0 && self.jitter <= 1.0) {
    raise Configuration("jitter must be 0..1")
  }
  if self.routing is Some(routing) {
    if self.discovery is None {
      raise Configuration("routing requires discovery=Some")
    }
    if routing.local_dc.is_empty() {
      raise Configuration("routing.local_dc must be nonempty")
    }
    validate_range(
      "routing.max_metadata_age_ms",
      routing.max_metadata_age_ms,
      1,
      2147483647,
    )
  }
  if self.discovery is Some(discovery) {
    validate_range(
      "discovery.refresh_interval_ms",
      discovery.refresh_interval_ms,
      1,
      2147483647,
    )
    validate_range("discovery.debounce_ms", discovery.debounce_ms, 0, 60000)
    validate_range("discovery.max_nodes", discovery.max_nodes, 1, 65536)
    validate_range(
      "discovery.max_tokens_per_node",
      discovery.max_tokens_per_node,
      1,
      65536,
    )
    validate_range("discovery.max_keyspaces", discovery.max_keyspaces, 1, 65536)
  }
}

///|
fn Session::stop(self : Session) -> Unit {
  if !self.closed {
    if self.draining && self.drain_outcome is None {
      self.drain_outcome = Some(Interrupted(self.active))
    }
    self.closed = true
    self.admission.close()
    self.schema_cache.entry = None
    if self.control is Some(control) {
      if control.connection is Some(connection) {
        connection.close()
      }
      if control.worker is Some(worker) {
        worker.cancel()
      }
    }
    for node in self.nodes {
      node.close_connections()
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
      if node.representative() is Some(_) {
        state = Ready
      } else if state != Ready && node.state() == Connecting {
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
      state: node.state(),
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
async fn[G] Session::maintain_slot(
  self : Session,
  node : SessionNode,
  slot : PoolSlot,
  group : @async.TaskGroup[G],
) -> Unit {
  defer {
    slot.state = Stopped
    self.changed.broadcast()
  }
  let random = @random.Rand::new()
  let mut backoff = self.config.backoff_initial_ms
  while !self.closed && !self.draining {
    slot.state = Connecting
    self.changed.broadcast()
    let connection = Some(self.connect_pool_node(node, group, Some(slot))) catch {
      error => {
        node.last_error = Some(error)
        slot.last_error = Some(error)
        self.last_error = Some(error)
        None
      }
    }
    if connection is Some(connection) {
      if self.closed || self.draining {
        connection.shutdown()
        return
      }
      let since = @async.now()
      {
        slot.current = Some(connection)
        let replacement = slot.generation > 0
        node.generation += 1
        slot.generation = node.generation
        connection.pool_slot = slot.index
        if replacement && self.config.connection.metrics is Some(metrics) {
          metrics.data.reconnects += 1L
          metrics.emit(Reconnected(node.endpoint, node.generation, false))
        }
        self.generation += 1
        connection.generation = slot.generation
        slot.state = Ready
        node.last_error = None
        slot.last_error = None
        self.last_error = None
        self.changed.broadcast()
        // 单个槽只回收自己的连接，同节点及其他节点的连接继续服务。
        defer @async.protect_from_cancel(() => {
          connection.shutdown()
          slot.current = None
          self.changed.broadcast()
        })
        connection.wait_closed()
        node.last_error = connection.failure
        slot.last_error = connection.failure
        self.last_error = connection.failure
      }
      if @async.now() - since >= self.config.stable_reset_ms.to_int64() {
        backoff = self.config.backoff_initial_ms
      }
    }
    if self.closed || self.draining {
      return
    }
    slot.state = Backoff
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
  bytes : Int64,
) -> Connection? {
  let indices = self.plan_indices(hint, attempted)
  if indices.is_empty() {
    return None
  }
  for index in indices {
    if self.nodes[index].choose(bytes) is Some(connection) {
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
  hint? : RoutingHint,
  attempted? : Array[String] = [],
) -> Connection {
  if self.closed {
    raise Closed
  }
  self.admission.validate_size(bytes)
  if bytes > self.config.connection.max_in_flight_bytes.to_int64() {
    raise Overloaded(RequestTooLarge)
  }
  if self.admission.turns.is_empty() &&
    self.choose(hint, attempted, bytes) is Some(connection) {
    return connection
  }
  // 有健康候选却无额度时按策略拒绝；节点不可用仍使用原有恢复等待语义。
  let candidates = self.plan_indices(hint, attempted)
  if !candidates.is_empty() &&
    (
      (
        self.config.enforce_limits &&
        self.config.limits.overload_policy == Reject
      ) ||
      self.config.connection.overload_policy == Reject
    ) &&
    self.nodes[candidates[0]].representative() is Some(connection) &&
    connection.admission.block_reason(bytes) is Some(reason) {
    raise reason
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
  self.admission.enter_wait(bytes)
  let turn = self.admission.enqueue_turn(bytes)
  self.waiting += 1
  self.waiting_bytes += bytes
  if self.config.connection.metrics is Some(metrics) {
    metrics.gauges(0L, 0L, 1L, bytes)
  }
  defer {
    self.admission.remove_turn(turn)
    self.admission.leave_wait(bytes)
    self.waiting -= 1
    self.waiting_bytes -= bytes
    if self.config.connection.metrics is Some(metrics) {
      metrics.gauges(0L, 0L, -1L, -bytes)
    }
    self.changed.broadcast()
  }
  let full = !self.plan_indices(hint, attempted).is_empty()
  let remaining = deadline.remaining_ms()
  let queue_limited = full &&
    self.config.connection.queue_timeout_ms < remaining
  let context = TimeoutContext::{
    phase: if full {
      WaitingSlot
    } else {
      WaitingConnection
    },
    sent: false,
  }
  timed(
    if queue_limited {
      self.config.connection.queue_timeout_ms
    } else {
      remaining
    },
    if queue_limited {
      Queue
    } else {
      Operation
    },
    context,
    () => {
      while !self.closed {
        if self.admission.owns_turn(turn) &&
          self.choose(hint, attempted, bytes) is Some(connection) {
          return connection
        }
        context.phase = if self.plan_indices(hint, attempted).is_empty() {
          WaitingConnection
        } else {
          WaitingSlot
        }
        self.changed.wait()
        self.admission.scheduling.wakeups += 1L
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
  self.with_operation(
    RequestOperation,
    () => {
      self.request_accepted(
        request,
        deadline,
        idempotent,
        retry,
        routing,
        self.config.execution_profile.bind(profile => profile.backoff),
      )
    },
    outcome=reply => {
      match reply.response {
        Failure(error) => ServerError(error.code)
        _ => Succeeded
      }
    },
  )
}

///|
async fn Session::request_accepted(
  self : Session,
  request : @protocol.Request,
  deadline : Deadline,
  idempotent : Bool,
  retry : RetryPolicy,
  routing : RoutingHint?,
  backoff : RetryBackoff?,
) -> Reply {
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
    backoff?,
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
/// 执行一次逻辑查询；默认不重放，只有显式幂等且策略允许时才重试。
pub async fn Session::query_with_profile(
  self : Session,
  cql : String,
  values? : Array[@types.Value] = [],
  options? : @protocol.QueryOptions,
  deadline? : Deadline,
  idempotent? : Bool = false,
  retry? : RetryPolicy,
  routing? : RoutingHint,
  profile? : ExecutionProfile,
) -> @protocol.ResultSet {
  self.query_with_profile_info(
    cql,
    values~,
    options?,
    deadline?,
    idempotent~,
    retry?,
    routing?,
    profile?,
  ).value catch {
    ExecutionError(error, _) => raise error
    error => raise error
  }
}

///|
pub async fn Session::query(
  self : Session,
  cql : String,
  values? : Array[@types.Value] = [],
  options? : @protocol.QueryOptions,
  deadline? : Deadline,
  idempotent? : Bool = false,
  retry? : RetryPolicy,
  routing? : RoutingHint,
) -> @protocol.ResultSet {
  self.query_with_profile(
    cql,
    values~,
    options?,
    deadline?,
    idempotent~,
    retry?,
    routing?,
  )
}
