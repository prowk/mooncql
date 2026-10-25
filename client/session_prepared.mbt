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
  request_options : @protocol.RequestOptions?
  profile : ExecutionProfile?
  states : Map[String, SessionPreparedState]
  mut parameters : Array[@protocol.Column]
  mut partition_key_indices : Array[Int]
  mut routing_keyspace : String?
}

///|
/// 创建 Session 逻辑语句并保留实际 PREPARE 信息；物理 ID 按节点、槽和连接代次隔离。
pub async fn Session::prepare_with_info(
  self : Session,
  cql : String,
  keyspace? : String,
  deadline? : Deadline,
  request_options? : @protocol.RequestOptions,
  profile? : ExecutionProfile,
) -> Execution[SessionPrepared] {
  let profile = self.execution_profile(profile)
  let deadline = profile_deadline(
    profile,
    deadline,
    self.config.connection.operation_timeout_ms,
  )
  let request_options = request_options.map(options => options.snapshot())
  let request = @protocol.prepare(cql, keyspace?, request_options?)
  if request.body.length() > self.config.connection.max_frame_bytes {
    raise Configuration("request exceeds frame limit")
  }
  self.with_operation(PrepareOperation, () => {
    let connection = self.select(
      deadline,
      request.body.length().to_int64() + 9L,
    )
    let statement = SessionPrepared::{
      session: self,
      cql,
      keyspace,
      request_options,
      profile,
      states: Map([]),
      parameters: [],
      partition_key_indices: [],
      routing_keyspace: None,
    }
    let prepared = statement.statement_for(
      connection,
      deadline,
      request.body.length().to_int64() + 9L,
    )
    { value: statement, info: prepared.info, }
  })
}

///|
async fn SessionPrepared::statement_for(
  self : SessionPrepared,
  connection : Connection,
  deadline : Deadline,
  charge : Int64,
) -> Execution[Prepared] {
  let node = "\{connection.config.host}:\{connection.config.port}/\{connection.pool_slot}"
  let state = match self.states.get(node) {
    Some(state) => state
    None => {
      // 成员替换后移除旧节点状态，避免长期发现新成员时累积连接引用。
      let live : Map[String, Bool] = Map([])
      for node in self.session.nodes {
        for slot in node.slots {
          live["\{node.endpoint.host}:\{node.endpoint.port}/\{slot.index}"] = true
        }
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
  deadline.with_lock(
    state.mutex,
    () => {
      if state.prepared is Some(prepared) &&
        state.generation == connection.generation &&
        physical_equal(prepared.connection, connection) {
        return {
          value: prepared,
          info: {
            ..copy_execution_info(prepared.origin_info),
            cached: true,
            attempt_count: 0,
          },
        }
      }
      let execution = connection.prepare_with_info(
        self.cql,
        keyspace?=self.keyspace,
        deadline~,
        request_options?=self.request_options,
      )
      let prepared = execution.value
      state.prepared = Some(prepared)
      state.generation = connection.generation
      self.accept_routing_metadata(prepared)
      execution
    },
    metrics?=connection.config.metrics,
    admission=connection.admission,
    bytes=charge,
  )
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
  @protocol.columns_snapshot(self.parameters)
}

///|
/// 使用选定物理连接的准备状态；选连接、必要的重新准备与重试共用同一预算。
pub async fn SessionPrepared::execute_with_info(
  self : SessionPrepared,
  values : Array[@types.Value],
  options? : @protocol.QueryOptions,
  deadline? : Deadline,
  idempotent? : Bool = false,
  retry? : RetryPolicy,
  profile? : ExecutionProfile,
) -> Execution[@protocol.ResultSet] {
  let profile = self.execution_profile(profile)
  let options = profile_options(profile, options)
  let retry = profile_retry(profile, retry)
  let deadline = profile_deadline(
    profile,
    deadline,
    self.session.config.connection.operation_timeout_ms,
  )
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
  self.session.with_operation(ExecuteOperation, () => {
    self.session.execute_retry(
      deadline,
      charge,
      idempotent,
      retry,
      hint,
      connection => {
        let preparation = self.statement_for(connection, deadline, charge)
        let prepared = preparation.value
        let result = prepared.execute_with_info(values, options~, deadline~) catch {
          ExecutionError(error, info) => {
            let previous = if preparation.info.cached {
              info.previous.copy()
            } else {
              [preparation.info]
            }
            if !preparation.info.cached {
              for prior in info.previous {
                previous.push(prior)
              }
            }
            raise ExecutionError(error, { ..info, previous, })
          }
          error => raise error
        }
        self.accept_routing_metadata(prepared)
        if preparation.info.cached {
          result
        } else {
          let previous = [preparation.info]
          for prior in result.info.previous {
            previous.push(prior)
          }
          { ..result, info: { ..result.info, previous, }, }
        }
      },
      backoff?=profile.bind(profile => profile.backoff),
      complete=(result, failures) => {
        let previous = []
        let mut attempts = result.info.attempt_count
        for failure in failures {
          if failure.execution_info is Some(info) {
            previous.push(info)
            attempts += info.attempt_count
          } else {
            attempts += 1
          }
        }
        for info in result.info.previous {
          previous.push(info)
        }
        {
          ..result,
          info: { ..result.info, attempt_count: attempts, previous, },
        }
      },
    )
  })
}

///|
pub async fn SessionPrepared::execute_conditional(
  self : SessionPrepared,
  values : Array[@types.Value],
  options? : @protocol.QueryOptions,
  deadline? : Deadline,
  profile? : ExecutionProfile,
) -> ConditionalResult {
  conditional_result(self.execute(values, options?, deadline?, profile?))
}

///|
pub async fn SessionPrepared::execute(
  self : SessionPrepared,
  values : Array[@types.Value],
  options? : @protocol.QueryOptions,
  deadline? : Deadline,
  idempotent? : Bool = false,
  retry? : RetryPolicy,
  profile? : ExecutionProfile,
) -> @protocol.ResultSet {
  self.execute_with_info(
    values,
    options?,
    deadline?,
    idempotent~,
    retry?,
    profile?,
  ).value catch {
    ExecutionError(error, _) => raise error
    error => raise error
  }
}

///|
/// 准备可跨连接恢复的逻辑语句，保存显式 keyspace 和执行配置；底层 Prepared 仍绑定物理连接。
pub async fn Session::prepare(
  self : Session,
  cql : String,
  keyspace? : String,
  deadline? : Deadline,
  request_options? : @protocol.RequestOptions,
  profile? : ExecutionProfile,
) -> SessionPrepared {
  self.prepare_with_info(cql, keyspace?, deadline?, request_options?, profile?).value catch {
    ExecutionError(error, _) => raise error
    error => raise error
  }
}
