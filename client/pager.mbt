///|
enum PageQuery {
  Simple(Connection, String, Array[@types.Value])
  PreparedQuery(Prepared, Array[@types.Value])
}

///|
pub struct Pager {
  query : PageQuery
  options : @protocol.QueryOptions
  mut state : Bytes?
  mut done : Bool
  mut busy : Bool
  mut columns : Array[@protocol.Column]
}

///|
pub fn Connection::pages(
  self : Connection,
  cql : String,
  values? : Array[@types.Value] = [],
  options? : @protocol.QueryOptions = @protocol.QueryOptions::new(
    page_size=1000,
  ),
) -> Pager raise {
  {
    query: Simple(self, cql, @types.snapshot(values)),
    options,
    state: options.paging_state,
    done: false,
    busy: false,
    columns: [],
  }
}

///|
pub fn Prepared::pages(
  self : Prepared,
  values : Array[@types.Value],
  options? : @protocol.QueryOptions = @protocol.QueryOptions::new(
    page_size=1000,
  ),
) -> Pager raise {
  {
    query: PreparedQuery(self, @types.snapshot(values)),
    options,
    state: options.paging_state,
    done: false,
    busy: false,
    columns: [],
  }
}

///|
pub async fn Pager::next(self : Pager) -> @protocol.Page? {
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
  let options = @protocol.QueryOptions::{
    consistency: self.options.consistency,
    page_size: self.options.page_size,
    paging_state: self.state,
    serial_consistency: self.options.serial_consistency,
    timestamp: self.options.timestamp,
  }
  let result = match self.query {
    Simple(connection, cql, values) =>
      connection.run(
        @protocol.query(cql, values~, options~),
        cached=self.columns,
      )
    PreparedQuery(statement, values) => statement.execute(values, options~)
  }
  guard result is Rows(page) else {
    raise Unexpected("pager requires ROWS result")
  }
  if page.paging_state is Some(_) && page.paging_state == self.state {
    self.done = true
    raise Unexpected("server returned unchanged paging state")
  }
  self.columns = page.columns
  self.state = page.paging_state
  self.done = self.state is None
  Some(page)
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
