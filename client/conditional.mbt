///|
pub(all) struct ConditionalResult {
  applied : Bool
  page : @protocol.Page
} derive(@debug.Debug)

///|
pub extend ConditionalResult with @debug.Debug::{to_repr}

///|
fn conditional_result(
  result : @protocol.ResultSet,
) -> ConditionalResult raise DriverError {
  guard result is Rows(page) && page.rows.length() == 1 else {
    raise Unexpected("conditional write requires a single result row")
  }
  let mut applied = None
  for i, column in page.columns {
    if column.name == "[applied]" {
      if applied is Some(_) || column.typ != @types.CqlType::Boolean {
        raise Unexpected("invalid conditional applied metadata")
      }
      guard page.rows[0][i] is @types.Value::Boolean(value) else {
        raise Unexpected("conditional applied value must be boolean")
      }
      applied = Some(value)
    }
  }
  guard applied is Some(value) else {
    raise Unexpected("missing conditional applied column")
  }
  { applied: value, page, }
}

///|
/// 执行 IF 条件写入；未应用是正常结果，当前值保留在 page 中。
pub async fn Connection::query_conditional(
  self : Connection,
  cql : String,
  values~ : Array[@types.Value] = [],
  options~ : @protocol.QueryOptions = @protocol.QueryOptions::new(),
  deadline? : Deadline,
) -> ConditionalResult {
  // QUERY 没有 EXECUTE 的 LWT 元数据特例，首次条件查询必须请求列定义。
  let options = { ..options, skip_metadata: false, }
  conditional_result(self.query(cql, values~, options~, deadline?))
}

///|
/// 即使设置 skip_metadata，也按 LWT 本次返回的完整列定义解释结果。
pub async fn Prepared::execute_conditional(
  self : Prepared,
  values : Array[@types.Value],
  options~ : @protocol.QueryOptions = @protocol.QueryOptions::new(),
  deadline? : Deadline,
) -> ConditionalResult {
  conditional_result(self.execute(values, options~, deadline?))
}
