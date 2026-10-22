///|
pub(all) struct ExecutionInfo {
  coordinator : Endpoint
  attempt_count : Int
  warnings : Array[String]
  tracing_id : Bytes?
  custom_payload : Map[String, Bytes?]
  previous : Array[ExecutionInfo]
  cached : Bool
  schema_agreement : SchemaAgreement?
}

///|
pub(all) struct Execution[T] {
  value : T
  info : ExecutionInfo
}

///|
pub(all) suberror ExecutionError {
  ExecutionError(Error, ExecutionInfo)
}

///|
fn copy_execution_info(info : ExecutionInfo) -> ExecutionInfo {
  let payload : Map[String, Bytes?] = Map([])
  for key, value in info.custom_payload {
    payload[key] = value
  }
  {
    ..info,
    warnings: info.warnings.copy(),
    custom_payload: payload,
    previous: info.previous.map(copy_execution_info),
    schema_agreement: info.schema_agreement.map(agreement => {
      agreement.snapshot()
    }),
  }
}

///|
fn error_with_history(error : Error, history : Array[ExecutionInfo]) -> Error {
  match error {
    ExecutionError(cause, info) => {
      let previous = history.copy()
      for prior in info.previous {
        previous.push(prior)
      }
      ExecutionError(cause, { ..info, previous, })
    }
    _ => {
      let previous = history.copy()
      match previous.pop() {
        Some(info) => ExecutionError(error, { ..info, previous, })
        None => error
      }
    }
  }
}

///|
pub fn Reply::execution_info(self : Reply) -> ExecutionInfo {
  {
    coordinator: self.coordinator,
    attempt_count: self.attempt_count,
    warnings: self.warnings,
    tracing_id: self.tracing_id,
    custom_payload: self.custom_payload,
    previous: self.previous,
    cached: false,
    schema_agreement: None,
  }
}

///|
pub async fn Connection::prepare(
  self : Connection,
  cql : String,
  keyspace? : String,
  deadline? : Deadline,
  request_options? : @protocol.RequestOptions,
) -> Prepared {
  self.prepare_internal(cql, keyspace?, deadline?, request_options?) catch {
    ExecutionError(error, _) => raise error
    error => raise error
  }
}

///|
pub async fn Connection::prepare_with_info(
  self : Connection,
  cql : String,
  keyspace? : String,
  deadline? : Deadline,
  request_options? : @protocol.RequestOptions,
) -> Execution[Prepared] {
  let effective_keyspace = if keyspace is Some(_) {
    keyspace
  } else {
    self.keyspace
  }
  let request = @protocol.prepare(
    cql,
    keyspace?=effective_keyspace,
    request_options?,
  )
  let cached = self.prepared_cache.entries.contains(request.body)
  let value = self.prepare_internal(cql, keyspace?, deadline?, request_options?)
  {
    value,
    info: {
      ..copy_execution_info(value.origin_info),
      cached,
      attempt_count: if cached {
        0
      } else {
        1
      },
    },
  }
}

///|
fn result_with_info(reply : Reply) -> Execution[@protocol.ResultSet] raise {
  let info = reply.execution_info()
  match reply.response {
    Result(value) => { value, info, }
    Failure(error) => raise ExecutionError(Server(error), info)
    _ => raise ExecutionError(Unexpected("expected RESULT response"), info)
  }
}

///|
pub async fn Connection::run_with_info(
  self : Connection,
  request : @protocol.Request,
  cached? : Array[@protocol.Column] = [],
  deadline? : Deadline,
) -> Execution[@protocol.ResultSet] {
  let execution = result_with_info(self.request(request, cached~, deadline?))
  if execution.value is SetKeyspace(name) {
    self.keyspace = Some(name)
    self.prepared_cache.clear()
  }
  execution
}

///|
pub async fn Connection::query_with_info(
  self : Connection,
  cql : String,
  values? : Array[@types.Value] = [],
  options? : @protocol.QueryOptions = @protocol.QueryOptions::new(),
  deadline? : Deadline,
) -> Execution[@protocol.ResultSet] {
  let deadline = self.operation_deadline(deadline)
  self.run_with_info(@protocol.query(cql, values~, options~), deadline~)
}

///|
pub async fn Connection::batch_with_info(
  self : Connection,
  statements : Array[@protocol.BatchStatement],
  kind? : @protocol.BatchType = Logged,
  options? : @protocol.QueryOptions = @protocol.QueryOptions::new(),
  deadline? : Deadline,
) -> Execution[Unit] {
  let deadline = self.operation_deadline(deadline)
  let execution = self.run_with_info(
    @protocol.batch(statements, kind~, options~),
    deadline~,
  )
  guard execution.value is Void else {
    raise ExecutionError(
      Unexpected("expected VOID batch result"),
      execution.info,
    )
  }
  { value: (), info: execution.info, }
}

///|
pub async fn Session::query_with_info(
  self : Session,
  cql : String,
  values? : Array[@types.Value] = [],
  options? : @protocol.QueryOptions = @protocol.QueryOptions::new(),
  deadline? : Deadline,
  idempotent? : Bool = false,
  retry? : RetryPolicy = RetryPolicy::new(),
  routing? : RoutingHint,
) -> Execution[@protocol.ResultSet] {
  let deadline = self.operation_deadline(deadline)
  let request = @protocol.query(cql, values~, options~)
  if request.body.length() > self.config.connection.max_frame_bytes {
    raise Configuration("request exceeds frame limit")
  }
  self.begin_operation()
  defer {
    self.active -= 1
    self.changed.broadcast()
  }
  self.finish_schema(
    result_with_info(
      self.request_accepted(request, deadline, idempotent, retry, routing),
    ),
    deadline,
  )
}
