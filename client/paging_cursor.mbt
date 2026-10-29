///|
pub struct PagingCursor {
  priv binding : Bytes
  priv state : Bytes?
  priv done : Bool
}

///|
// 游标可能含查询和绑定值，Debug 只展示是否完成，避免日志泄漏。
impl @debug.Debug for PagingCursor with fn to_repr(self) {
  @debug.Repr(
    if self.done {
      "PagingCursor(done)"
    } else {
      "PagingCursor(active)"
    },
  )
}

///|
pub extend PagingCursor with @debug.Debug::{to_repr}

///|
pub fn PagingCursor::is_done(self : PagingCursor) -> Bool {
  self.done
}

///|
pub fn PagingCursor::to_bytes(
  self : PagingCursor,
) -> Bytes raise @codec.CodecError {
  let state_size = self.state
    .map(state => state.length().to_int64())
    .unwrap_or(0L)
  if 17L + self.binding.length().to_int64() + state_size > 33554432L {
    raise @codec.CodecError("paging cursor exceeds 32 MiB")
  }
  let writer = @codec.Writer::new()
  writer.raw(b"MCQLPG01")
  writer.bytes(Some(self.binding))
  writer.u8(if self.done { 1 } else { 0 })
  writer.bytes(self.state)
  let bytes = writer.to_bytes()
  if bytes.length() > 33554432 {
    raise @codec.CodecError("paging cursor exceeds 32 MiB")
  }
  bytes
}

///|
pub fn PagingCursor::from_bytes(
  bytes : Bytes,
) -> PagingCursor raise @codec.CodecError {
  if bytes.length() > 33554432 {
    raise @codec.CodecError("paging cursor exceeds 32 MiB")
  }
  let reader = @codec.Reader::new(bytes)
  if reader.take(8) != b"MCQLPG01" {
    raise @codec.CodecError("unsupported paging cursor format")
  }
  let binding_size = reader.i32()
  if binding_size == -1 {
    raise @codec.CodecError("missing cursor binding")
  }
  if binding_size < 1 || binding_size > 16777216 {
    raise @codec.CodecError("invalid cursor binding size")
  }
  // 先验证声明长度，避免为了拒绝大上下文而先复制该上下文。
  let binding = reader.take(binding_size)
  let flag = reader.u8()
  if flag > 1 {
    raise @codec.CodecError("invalid cursor completion flag")
  }
  let state = reader.bytes()
  reader.finish()
  if flag == 1 && state is Some(_) {
    raise @codec.CodecError("completed cursor cannot have continuation state")
  }
  { binding, state, done: flag == 1, }
}

///|
fn paging_binding(
  cql : String,
  values : Array[@types.Value],
  options : @protocol.QueryOptions,
  prepare : @protocol.Request?,
) -> Bytes raise {
  let request = @protocol.query(cql, values~, options={
    ..options,
    paging_state: None,
  })
  let writer = @codec.Writer::new()
  writer.u8(if prepare is Some(_) { 2 } else { 1 })
  writer.u8(request.flags)
  writer.bytes(Some(request.body))
  if prepare is Some(prepare) {
    writer.u8(prepare.flags)
    writer.bytes(Some(prepare.body))
  }
  let binding = writer.to_bytes()
  if binding.length() > 16777216 {
    raise Configuration("paging binding exceeds 16 MiB")
  }
  binding
}

///|
fn new_pager(
  query : PageQuery,
  options : @protocol.QueryOptions,
  binding : Bytes,
  cursor : PagingCursor?,
  profile? : ExecutionProfile,
  idempotent~ : Bool = false,
  retry? : RetryPolicy,
  traversal_deadline? : Deadline,
) -> Pager raise DriverError {
  if cursor is Some(cursor) {
    if options.paging_state is Some(_) {
      raise Configuration("specify cursor or raw paging_state, not both")
    }
    if cursor.binding != binding {
      raise Configuration(
        "paging cursor does not match query, keyspace, bindings or execution options",
      )
    }
  }
  {
    query,
    options,
    binding,
    state: match cursor {
      Some(cursor) => cursor.state
      None => options.paging_state
    },
    done: match cursor {
      Some(cursor) => cursor.done
      None => false
    },
    busy: false,
    columns: [],
    timeout_ms: profile
    .bind(profile => profile.timeout)
    .unwrap_or_else(() => {
      match query {
        Simple(connection, _, _) => connection.config.operation_timeout_ms
        PreparedQuery(statement, _) =>
          statement.connection.config.operation_timeout_ms
        SessionQuery(session, _, _) =>
          session.config.connection.operation_timeout_ms
        SessionPreparedQuery(statement, _) =>
          statement.session.config.connection.operation_timeout_ms
      }
    }),
    traversal_timeout_ms: profile.bind(profile => profile.traversal_timeout),
    traversal_deadline,
    idempotent,
    retry: profile_retry(profile, retry),
    profile,
  }
}

///|
pub fn Pager::cursor(self : Pager) -> PagingCursor raise DriverError {
  if self.busy {
    raise Configuration("cannot capture cursor during an active next call")
  }
  if self.state.map(state => state.length().to_int64()).unwrap_or(0L) +
    self.binding.length().to_int64() >
    33554415L {
    raise Configuration("paging cursor exceeds 32 MiB")
  }
  { binding: self.binding, state: self.state, done: self.done, }
}
