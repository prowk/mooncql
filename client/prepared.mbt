///|
pub struct Prepared {
  connection : Connection
  cql : String
  keyspace : String?
  mut metadata : @protocol.PreparedStatement
  refresh_mutex : @async.Mutex
  mut generation : Int
}

///|
async fn Connection::prepare_metadata(
  self : Connection,
  cql : String,
  keyspace : String?,
  deadline : Deadline,
) -> @protocol.PreparedStatement {
  match self.run(@protocol.prepare(cql, keyspace?), deadline~) {
    Prepared(metadata) => metadata
    _ => raise Unexpected("expected PREPARED result")
  }
}

///|
pub async fn Connection::prepare(
  self : Connection,
  cql : String,
  keyspace? : String,
  deadline? : Deadline,
) -> Prepared {
  let deadline = self.operation_deadline(deadline)
  let keyspace = if keyspace is Some(_) { keyspace } else { self.keyspace }
  let cache_key = @protocol.prepare(cql, keyspace?).body
  deadline.with_lock(self.prepare_mutex, () => {
    if self.closed {
      raise Closed
    }
    if self.prepared_cache.get(cache_key) is Some(statement) {
      return statement
    }
    let metadata = self.prepare_metadata(cql, keyspace, deadline)
    let prepared = Prepared::{
      connection: self,
      cql,
      keyspace,
      metadata,
      refresh_mutex: @async.Mutex(),
      generation: 0,
    }
    // 限制缓存条数，未缓存的语句仍可通过返回对象正常执行。
    if self.prepared_cache.length() < 64 {
      self.prepared_cache[cache_key] = prepared
    }
    prepared
  })
}

///|
pub fn Prepared::parameters(self : Prepared) -> Array[@protocol.Column] {
  self.metadata.parameters.copy()
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
pub async fn Prepared::execute(
  self : Prepared,
  values : Array[@types.Value],
  options? : @protocol.QueryOptions = @protocol.QueryOptions::new(),
  deadline? : Deadline,
) -> @protocol.ResultSet {
  let deadline = self.connection.operation_deadline(deadline)
  // 整次执行及可能的一次恢复共用同一份参数快照。
  let options = prepared_options(options, self.keyspace)
  let values = @types.snapshot(values)
  self.validate_bindings(values)
  let metadata = self.metadata
  let generation = self.generation
  let reply = self.connection.request(
    @protocol.execute(
      metadata.id,
      metadata.result_metadata_id,
      values,
      options~,
    ),
    cached=metadata.result_columns,
    deadline~,
  )
  match reply.response {
    Result(result) => return self.accept_result(result, metadata)
    Failure(error) => {
      guard error.detail is Unprepared(id) && id == metadata.id else {
        raise Server(error)
      }
    }
    _ => raise Unexpected("expected RESULT response")
  }
  deadline.with_lock(self.refresh_mutex, () => {
    if self.generation == generation {
      self.metadata = self.connection.prepare_metadata(
        self.cql,
        self.keyspace,
        deadline,
      )
      self.generation += 1
    }
  })
  // 仅 UNPREPARED 可以触发一次恢复，超时、断连及写错误不重放。
  self.validate_bindings(values)
  let metadata = self.metadata
  self.accept_result(
    self.connection.run(
      @protocol.execute(
        metadata.id,
        metadata.result_metadata_id,
        values,
        options~,
      ),
      cached=metadata.result_columns,
      deadline~,
    ),
    metadata,
  )
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
      result_columns: page.columns,
    }
  }
  result
}
