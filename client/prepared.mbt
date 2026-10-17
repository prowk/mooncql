///|
pub struct Prepared {
  connection : Connection
  cql : String
  mut metadata : @protocol.PreparedStatement
  refresh_mutex : @async.Mutex
  mut generation : Int
}

///|
async fn Connection::prepare_metadata(
  self : Connection,
  cql : String,
) -> @protocol.PreparedStatement {
  match self.run(@protocol.prepare(cql)) {
    Prepared(metadata) => metadata
    _ => raise Unexpected("expected PREPARED result")
  }
}

///|
pub async fn Connection::prepare(self : Connection, cql : String) -> Prepared {
  self.prepare_mutex.acquire()
  defer self.prepare_mutex.release()
  if self.closed {
    raise Closed
  }
  if self.prepared_cache.get(cql) is Some(statement) {
    return statement
  }
  let metadata = self.prepare_metadata(cql)
  let prepared = Prepared::{
    connection: self,
    cql,
    metadata,
    refresh_mutex: @async.Mutex(),
    generation: 0,
  }
  // 限制缓存条数，未缓存的语句仍可通过返回对象正常执行。
  if self.prepared_cache.length() < 64 {
    self.prepared_cache[cql] = prepared
  }
  prepared
}

///|
pub fn Prepared::parameters(self : Prepared) -> Array[@protocol.Column] {
  self.metadata.parameters.copy()
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
) -> @protocol.ResultSet {
  // 整次执行及可能的一次恢复共用同一份参数快照。
  let values = @types.snapshot(values)
  self.validate_bindings(values)
  let metadata = self.metadata
  let generation = self.generation
  let reply = self.connection.request(
    @protocol.execute(metadata.id, values, options~),
    cached=metadata.result_columns,
  )
  match reply.response {
    Result(result) => return result
    Failure(error) => {
      guard error.detail is Unprepared(id) && id == metadata.id else {
        raise Server(error)
      }
    }
    _ => raise Unexpected("expected RESULT response")
  }
  {
    self.refresh_mutex.acquire()
    defer self.refresh_mutex.release()
    if self.generation == generation {
      self.metadata = self.connection.prepare_metadata(self.cql)
      self.generation += 1
    }
  }
  // 仅 UNPREPARED 可以触发一次恢复，超时、断连及写错误不重放。
  self.validate_bindings(values)
  self.connection.run(
    @protocol.execute(self.metadata.id, values, options~),
    cached=self.metadata.result_columns,
  )
}
