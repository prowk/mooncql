///|
pub fn Prepared::bind_batch(
  self : Prepared,
  values : Array[@types.Value],
) -> @protocol.BatchStatement raise {
  let values = @types.snapshot(values)
  self.validate_bindings(values)
  @protocol.BatchStatement::Prepared(self.metadata.id, values)
}

///|
pub async fn Connection::batch(
  self : Connection,
  statements : Array[@protocol.BatchStatement],
  kind~ : @protocol.BatchType = Logged,
  options~ : @protocol.QueryOptions = @protocol.QueryOptions::new(),
  deadline? : Deadline,
) -> Unit {
  let deadline = self.operation_deadline(deadline)
  guard self.run(@protocol.batch(statements, kind~, options~), deadline~)
    is Void else {
    raise Unexpected("expected VOID batch result")
  }
}
