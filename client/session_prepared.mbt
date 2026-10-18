///|
struct SessionPreparedState {
  mutex : @async.Mutex
  mut generation : Int
  mut prepared : Prepared?
}

///|
pub struct SessionPrepared {
  session : Session
  cql : String
  keyspace : String?
  states : Map[String, SessionPreparedState]
  mut parameters : Array[@protocol.Column]
  mut partition_key_indices : Array[Int]
  mut routing_keyspace : String?
}

///|
pub async fn Session::prepare(
  self : Session,
  cql : String,
  keyspace? : String,
  deadline? : Deadline,
) -> SessionPrepared {
  let deadline = self.operation_deadline(deadline)
  let request = @protocol.prepare(cql, keyspace?)
  if request.body.length() > self.config.connection.max_frame_bytes {
    raise Configuration("request exceeds frame limit")
  }
  self.active += 1
  defer {
    self.active -= 1
    self.changed.broadcast()
  }
  let connection = self.select(deadline, request.body.length().to_int64() + 9L)
  let statement = SessionPrepared::{
    session: self,
    cql,
    keyspace,
    states: Map([]),
    parameters: [],
    partition_key_indices: [],
    routing_keyspace: None,
  }
  ignore(statement.statement_for(connection, deadline))
  statement
}

///|
async fn SessionPrepared::statement_for(
  self : SessionPrepared,
  connection : Connection,
  deadline : Deadline,
) -> Prepared {
  let node = "\{connection.config.host}:\{connection.config.port}"
  let state = match self.states.get(node) {
    Some(state) => state
    None => {
      // 成员替换后移除旧节点状态，避免长期发现新成员时累积连接引用。
      let live : Map[String, Bool] = Map([])
      for node in self.session.nodes {
        live["\{node.endpoint.host}:\{node.endpoint.port}"] = true
      }
      for key in self.states.keys().to_array() {
        if !live.contains(key) {
          self.states.remove(key)
        }
      }
      let state = SessionPreparedState::{
        mutex: @async.Mutex(),
        generation: -1,
        prepared: None,
      }
      self.states[node] = state
      state
    }
  }
  deadline.with_lock(state.mutex, () => {
    if state.prepared is Some(prepared) &&
      state.generation == connection.generation &&
      physical_equal(prepared.connection, connection) {
      return prepared
    }
    let prepared = connection.prepare(
      self.cql,
      keyspace?=self.keyspace,
      deadline~,
    )
    state.prepared = Some(prepared)
    state.generation = connection.generation
    self.accept_routing_metadata(prepared)
    prepared
  })
}

///|
fn SessionPrepared::accept_routing_metadata(
  self : SessionPrepared,
  prepared : Prepared,
) -> Unit {
  self.parameters = prepared.parameters()
  self.partition_key_indices = prepared.metadata.partition_key_indices.copy()
  self.routing_keyspace = match self.keyspace {
    Some(keyspace) => Some(keyspace)
    None =>
      if self.partition_key_indices.get(0) is Some(index) &&
        index >= 0 &&
        index < self.parameters.length() {
        Some(self.parameters[index].keyspace)
      } else {
        None
      }
  }
}

///|
pub fn SessionPrepared::parameters(
  self : SessionPrepared,
) -> Array[@protocol.Column] {
  self.parameters.copy()
}

///|
pub async fn SessionPrepared::execute(
  self : SessionPrepared,
  values : Array[@types.Value],
  options? : @protocol.QueryOptions = @protocol.QueryOptions::new(),
  deadline? : Deadline,
  idempotent? : Bool = false,
  retry? : RetryPolicy = RetryPolicy::new(),
) -> @protocol.ResultSet {
  let deadline = self.session.operation_deadline(deadline)
  // 在选择连接前冻结参数，连接更换及重新准备都使用该快照。
  let values = @types.snapshot(values)
  let options = prepared_options(options, self.keyspace)
  let hint = if self.routing_keyspace is Some(keyspace) &&
    @routing.routing_key(values, self.partition_key_indices) is Some(key) {
    Some(RoutingHint::new(keyspace, key))
  } else {
    None
  }
  let charge = @protocol.execute(b"", b"", values, options~).body
    .length()
    .to_int64() +
    9L
  self.session.active += 1
  defer {
    self.session.active -= 1
    self.session.changed.broadcast()
  }
  self.session.execute_retry(deadline, charge, idempotent, retry, hint, connection => {
    let prepared = self.statement_for(connection, deadline)
    let result = prepared.execute(values, options~, deadline~)
    self.accept_routing_metadata(prepared)
    result
  })
}

///|
pub async fn SessionPrepared::execute_conditional(
  self : SessionPrepared,
  values : Array[@types.Value],
  options? : @protocol.QueryOptions = @protocol.QueryOptions::new(),
  deadline? : Deadline,
) -> ConditionalResult {
  conditional_result(self.execute(values, options~, deadline?))
}
