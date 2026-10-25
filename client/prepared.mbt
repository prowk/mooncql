///|
pub struct Prepared {
  connection : Connection
  cql : String
  keyspace : String?
  mut metadata : @protocol.PreparedStatement
  refresh_mutex : @async.Mutex
  mut generation : Int
  request_options : @protocol.RequestOptions?
  mut origin_info : ExecutionInfo
}

///|
async fn Connection::prepare_metadata(
  self : Connection,
  cql : String,
  keyspace : String?,
  deadline : Deadline,
  request_options : @protocol.RequestOptions?,
) -> Execution[@protocol.PreparedStatement] {
  let execution = self.run_with_info(
    @protocol.prepare(cql, keyspace?, request_options?),
    deadline~,
  )
  match execution.value {
    Prepared(value) => { value, info: execution.info, }
    _ =>
      raise ExecutionError(
        Unexpected("expected PREPARED result"),
        execution.info,
      )
  }
}

///|
async fn Connection::prepare_internal(
  self : Connection,
  cql : String,
  keyspace? : String,
  deadline? : Deadline,
  request_options? : @protocol.RequestOptions,
) -> Prepared {
  let deadline = self.operation_deadline(deadline)
  let keyspace = if keyspace is Some(_) { keyspace } else { self.keyspace }
  let request_options = request_options.map(options => options.snapshot())
  let cache_key = @protocol.prepare(cql, keyspace?, request_options?).body
  if self.closed {
    raise Closed
  }
  if cache_key.length() > self.config.max_frame_bytes {
    raise Configuration("request exceeds frame limit")
  }
  if self.prepared_cache.get(cache_key) is Some(statement) {
    return statement
  }
  let flight = self.prepare_flight(cache_key)
  let waiting = flight.users > 0
  if waiting {
    self.admission.enter_wait(cache_key.length().to_int64())
  }
  flight.users += 1
  defer {
    if waiting {
      self.admission.leave_wait(cache_key.length().to_int64())
    }
    self.leave_prepare(cache_key, flight)
  }
  deadline.with_lock(
    flight.mutex,
    () => {
      if self.closed {
        raise Closed
      }
      if flight.result is Some(statement) {
        return statement
      }
      if flight.failure is Some(error) {
        raise error
      }
      let outcome = Ok(
        self.prepare_metadata(cql, keyspace, deadline, request_options),
      ) catch {
        error => Err(error)
      }
      let metadata = match outcome {
        Ok(metadata) => metadata
        Err(error) => {
          flight.failure = Some(error)
          raise error
        }
      }
      let prepared = Prepared::{
        connection: self,
        cql,
        keyspace,
        metadata: metadata.value,
        request_options,
        origin_info: metadata.info,
        refresh_mutex: @async.Mutex(),
        generation: 0,
      }
      flight.result = Some(prepared)
      if !self.closed {
        self.prepared_cache.store(cache_key, prepared)
      }
      prepared
    },
    metrics?=self.config.metrics,
    bytes=cache_key.length().to_int64(),
  )
}

///|
pub fn Prepared::parameters(self : Prepared) -> Array[@protocol.Column] {
  @protocol.columns_snapshot(self.metadata.parameters)
}

///|
fn prepared_options(
  options : @protocol.QueryOptions,
  keyspace : String?,
) -> @protocol.QueryOptions raise DriverError {
  if options.value_names is Some(_) {
    raise Configuration("prepared statements use positional bindings")
  }
  if options.keyspace is Some(_) && options.keyspace != keyspace {
    raise Configuration("execute keyspace differs from prepared keyspace")
  }
  { ..options.snapshot(), keyspace, }
}

///|
fn Prepared::validate_bindings(
  self : Prepared,
  values : Array[@types.Value],
) -> Unit raise {
  if values.length() != self.metadata.parameters.length() {
    raise Configuration("incorrect prepared parameter count")
  }
  for i, value in values {
    @types.validate(self.metadata.parameters[i].typ, value)
  }
}

///|
pub async fn Prepared::execute_with_info(
  self : Prepared,
  values : Array[@types.Value],
  options? : @protocol.QueryOptions = @protocol.QueryOptions::new(),
  deadline? : Deadline,
) -> Execution[@protocol.ResultSet] {
  let deadline = self.connection.operation_deadline(deadline)
  // 整次执行及可能的一次恢复共用同一份参数快照。
  let options = prepared_options(options, self.keyspace)
  let values = @types.snapshot(values)
  self.execute_frozen(values, options, deadline)
}

///|
// 仅接收驱动已经持有的参数快照，Session 重试不再逐次重复深拷贝。
async fn Prepared::execute_frozen(
  self : Prepared,
  values : Array[@types.Value],
  options : @protocol.QueryOptions,
  deadline : Deadline,
) -> Execution[@protocol.ResultSet] {
  self.validate_bindings(values)
  let metadata = self.metadata
  let generation = self.generation
  let request = @protocol.execute(
    metadata.id,
    metadata.result_metadata_id,
    values,
    options~,
  )
  let request_bytes = request.body.length().to_int64() + 9L
  let reply = self.connection.request(
    request,
    cached=metadata.result_columns,
    deadline~,
  )
  match reply.response {
    Result(result) =>
      return {
        value: self.accept_result(result, metadata),
        info: reply.execution_info(),
      }
    Failure(error) => {
      guard error.detail is Unprepared(id) && id == metadata.id else {
        raise ExecutionError(Server(error), reply.execution_info())
      }
    }
    _ =>
      raise ExecutionError(
        Unexpected("expected RESULT response"),
        reply.execution_info(),
      )
  }
  let previous = [reply.execution_info()]
  deadline.with_lock(
    self.refresh_mutex,
    () => {
      if self.generation == generation {
        let prepared = self.connection.prepare_metadata(
          self.cql,
          self.keyspace,
          deadline,
          self.request_options,
        )
        self.metadata = prepared.value
        self.origin_info = prepared.info
        previous.push(copy_execution_info(prepared.info))
        self.generation += 1
      }
    },
    metrics?=self.connection.config.metrics,
    admission=self.connection.admission,
    bytes=request_bytes,
  ) catch {
    ExecutionError(error, info) => {
      let prior = previous.copy()
      for previous in info.previous {
        prior.push(previous)
      }
      raise ExecutionError(error, { ..info, previous: prior, })
    }
    error => raise error_with_history(error, previous)
  }
  // 仅 UNPREPARED 可以触发一次恢复，超时、断连及写错误不重放。
  self.validate_bindings(values) catch {
    error => raise error_with_history(error, previous)
  }
  let metadata = self.metadata
  let result = self.connection.run_with_info(
    @protocol.execute(
      metadata.id,
      metadata.result_metadata_id,
      values,
      options~,
    ),
    cached=metadata.result_columns,
    deadline~,
  ) catch {
    ExecutionError(error, info) =>
      raise ExecutionError(error, { ..info, attempt_count: 2, previous, })
    error => raise error_with_history(error, previous)
  }
  {
    value: self.accept_result(result.value, metadata),
    info: { ..result.info, attempt_count: 2, previous, },
  }
}

///|
fn Prepared::accept_result(
  self : Prepared,
  result : @protocol.ResultSet,
  sent : @protocol.PreparedStatement,
) -> @protocol.ResultSet {
  if result is Rows(page) &&
    page.new_metadata_id is Some(id) &&
    self.metadata.id == sent.id &&
    self.metadata.result_metadata_id == sent.result_metadata_id {
    // 并发旧请求不能把已经更新的元数据覆盖回旧版本。
    self.metadata = {
      id: sent.id,
      result_metadata_id: id,
      parameters: sent.parameters,
      partition_key_indices: sent.partition_key_indices,
      result_columns: page.columns_snapshot(),
    }
  }
  result
}

///|
pub async fn Prepared::execute(
  self : Prepared,
  values : Array[@types.Value],
  options? : @protocol.QueryOptions = @protocol.QueryOptions::new(),
  deadline? : Deadline,
) -> @protocol.ResultSet {
  self.execute_with_info(values, options~, deadline?).value catch {
    ExecutionError(error, _) => raise error
    error => raise error
  }
}
