///|
enum PageQuery {
  Simple(Connection, String, Array[@types.Value])
  PreparedQuery(Prepared, Array[@types.Value])
  SessionQuery(Session, String, Array[@types.Value])
  SessionPreparedQuery(SessionPrepared, Array[@types.Value])
}

///|
pub struct Pager {
  query : PageQuery
  options : @protocol.QueryOptions
  mut state : Bytes?
  mut done : Bool
  mut busy : Bool
  mut columns : Array[@protocol.Column]
  binding : Bytes
  timeout_ms : Int
  traversal_timeout_ms : Int?
  mut traversal_deadline : Deadline?
  idempotent : Bool
  retry : RetryPolicy
  profile : ExecutionProfile?
}

///|
pub fn Connection::pages_with_options(
  self : Connection,
  cql : String,
  values? : Array[@types.Value] = [],
  options? : @protocol.QueryOptions = @protocol.QueryOptions::new(
    page_size=1000,
  ),
  cursor? : PagingCursor,
  traversal_deadline? : Deadline,
) -> Pager raise {
  let values = @types.snapshot(values)
  let options = {
    ..options.snapshot(),
    keyspace: if options.keyspace is Some(_) {
      options.keyspace
    } else {
      self.keyspace
    },
  }
  new_pager(
    Simple(self, cql, values),
    options,
    paging_binding(cql, values, options, None),
    cursor,
    traversal_deadline?,
  )
}

///|
pub fn Prepared::pages_with_options(
  self : Prepared,
  values : Array[@types.Value],
  options? : @protocol.QueryOptions = @protocol.QueryOptions::new(
    page_size=1000,
  ),
  cursor? : PagingCursor,
  traversal_deadline? : Deadline,
) -> Pager raise {
  let values = @types.snapshot(values)
  let options = prepared_options(options, self.keyspace)
  let prepare = @protocol.prepare(
    self.cql,
    keyspace?=self.keyspace,
    request_options?=self.request_options,
  )
  new_pager(
    PreparedQuery(self, values),
    options,
    paging_binding(self.cql, values, options, Some(prepare)),
    cursor,
    traversal_deadline?,
  )
}

///|
pub fn Session::pages_with_options(
  self : Session,
  cql : String,
  values? : Array[@types.Value] = [],
  options? : @protocol.QueryOptions,
  cursor? : PagingCursor,
  profile? : ExecutionProfile,
  idempotent? : Bool = false,
  retry? : RetryPolicy,
  traversal_deadline? : Deadline,
) -> Pager raise {
  let values = @types.snapshot(values)
  let profile = self.execution_profile(profile)
  let options = profile_options(profile, options, paging=true)
  new_pager(
    SessionQuery(self, cql, values),
    options,
    paging_binding(cql, values, options, None),
    cursor,
    profile?,
    idempotent~,
    retry?,
    traversal_deadline?,
  )
}

///|
pub fn SessionPrepared::pages_with_options(
  self : SessionPrepared,
  values : Array[@types.Value],
  options? : @protocol.QueryOptions,
  cursor? : PagingCursor,
  profile? : ExecutionProfile,
  idempotent? : Bool = false,
  retry? : RetryPolicy,
  traversal_deadline? : Deadline,
) -> Pager raise {
  let values = @types.snapshot(values)
  let profile = self.execution_profile(profile)
  let options = prepared_options(
    profile_options(profile, options, paging=true),
    self.keyspace,
  )
  let prepare = @protocol.prepare(
    self.cql,
    keyspace?=self.keyspace,
    request_options?=self.request_options,
  )
  new_pager(
    SessionPreparedQuery(self, values),
    options,
    paging_binding(self.cql, values, options, Some(prepare)),
    cursor,
    profile?,
    idempotent~,
    retry?,
    traversal_deadline?,
  )
}

///|
pub async fn Pager::next_with_info(
  self : Pager,
  deadline? : Deadline,
) -> Execution[@protocol.Page]? {
  if self.busy {
    raise Configuration("pager already has an active next call")
  }
  if self.done {
    return None
  }
  self.busy = true
  defer {
    self.busy = false
  }
  // 整次遍历从第一次取页计时，包含调用方处理行及两页之间的等待。
  if self.traversal_deadline is None &&
    self.traversal_timeout_ms is Some(timeout) {
    self.traversal_deadline = Some(Deadline::after(timeout))
  }
  let page_deadline = deadline.unwrap_or_else(() => {
    Deadline::after(self.timeout_ms)
  })
  let deadline = match self.traversal_deadline {
    Some(total) =>
      if total.at < page_deadline.at {
        total
      } else {
        page_deadline
      }
    None => page_deadline
  }
  if deadline.remaining_ms() <= 0 {
    if self.traversal_deadline is Some(total) && total.at <= deadline.at {
      raise OperationTimedOut(WaitingPage, {
        phase: WaitingSlot,
        scope: Operation,
        may_have_been_sent: false,
      })
    }
    raise TimedOut({
      phase: WaitingSlot,
      scope: Operation,
      may_have_been_sent: false,
    })
  }
  let options = @protocol.QueryOptions::{
    consistency: self.options.consistency,
    page_size: self.options.page_size,
    paging_state: self.state,
    serial_consistency: self.options.serial_consistency,
    timestamp: self.options.timestamp,
    keyspace: self.options.keyspace,
    now_in_seconds: self.options.now_in_seconds,
    value_names: self.options.value_names,
    // 首次或恢复后的普通查询需要完整元数据；Session 每页可能更换协调节点。
    skip_metadata: self.options.skip_metadata &&
    (match self.query {
      Simple(_, _, _) => self.columns.length() > 0
      SessionQuery(_, _, _) => false
      _ => true
    }),
    request_options: self.options.request_options,
  }
  let result = match self.query {
    Simple(connection, cql, values) =>
      connection.run_with_info(
        @protocol.query(cql, values~, options~),
        cached=self.columns,
        deadline~,
      )
    PreparedQuery(statement, values) =>
      statement.execute_frozen(
        values,
        prepared_options(options, statement.keyspace),
        deadline,
      )
    SessionQuery(session, cql, values) =>
      session.query_with_profile_info(
        cql,
        values~,
        options~,
        deadline~,
        idempotent=self.idempotent,
        retry=self.retry,
        profile?=self.profile,
      )
    SessionPreparedQuery(statement, values) =>
      statement.execute_with_profile_info(
        values,
        options~,
        deadline~,
        idempotent=self.idempotent,
        retry=self.retry,
        profile?=self.profile,
      )
  }
  guard result.value is Rows(page) else {
    raise ExecutionError(Unexpected("pager requires ROWS result"), result.info)
  }
  if page.paging_state is Some(_) && page.paging_state == self.state {
    raise ExecutionError(
      Unexpected("server returned unchanged paging state"),
      result.info,
    )
  }
  self.columns = page.columns_snapshot()
  self.state = page.paging_state
  self.done = self.state is None
  Some({ value: page, info: result.info, })
}

///|
pub async fn Pager::for_each_row(
  self : Pager,
  visit : async (Array[@protocol.Column], Array[@types.Value]) -> Unit,
) -> Unit {
  while self.next() is Some(page) {
    for row in page.rows {
      visit(page.columns, row)
    }
  }
}

///|
pub async fn Pager::next(self : Pager, deadline? : Deadline) -> @protocol.Page? {
  self.next_with_info(deadline?).map(execution => execution.value) catch {
    ExecutionError(error, _) => raise error
    error => raise error
  }
}

///|
pub fn Connection::pages(
  self : Connection,
  cql : String,
  values? : Array[@types.Value] = [],
  options? : @protocol.QueryOptions = @protocol.QueryOptions::new(
    page_size=1000,
  ),
  cursor? : PagingCursor,
) -> Pager raise {
  self.pages_with_options(cql, values~, options~, cursor?)
}

///|
pub fn Prepared::pages(
  self : Prepared,
  values : Array[@types.Value],
  options? : @protocol.QueryOptions = @protocol.QueryOptions::new(
    page_size=1000,
  ),
  cursor? : PagingCursor,
) -> Pager raise {
  self.pages_with_options(values, options~, cursor?)
}

///|
pub fn Session::pages(
  self : Session,
  cql : String,
  values? : Array[@types.Value] = [],
  options? : @protocol.QueryOptions,
  cursor? : PagingCursor,
) -> Pager raise {
  self.pages_with_options(cql, values~, options?, cursor?)
}

///|
pub fn SessionPrepared::pages(
  self : SessionPrepared,
  values : Array[@types.Value],
  options? : @protocol.QueryOptions,
  cursor? : PagingCursor,
) -> Pager raise {
  self.pages_with_options(values, options?, cursor?)
}
