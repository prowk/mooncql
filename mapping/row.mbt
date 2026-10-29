///|
pub(all) enum MissingColumnPolicy {
  RejectMissing
  MissingAsNull
} derive(Eq, @debug.Debug)

///|
pub extend MissingColumnPolicy with Eq::{equal, not_equal}

///|
pub extend MissingColumnPolicy with @debug.Debug::{to_repr}

///|
pub struct RowReader {
  columns : Array[@protocol.Column]
  values : Array[@types.Value]
  missing : MissingColumnPolicy
}

///|
pub struct RowCodec[T] {
  decode : (RowReader) -> T raise
}

///|
/// 用字段读取回调构造行映射器，不推断结构字段或自动生成 CQL。
pub fn[T] RowCodec::new(decode : (RowReader) -> T raise) -> RowCodec[T] {
  { decode, }
}

///|
/// 冻结并校验整行后调用回调；默认缺列报错，NULL 由字段编解码器决定。
pub fn[T] RowCodec::decode(
  self : RowCodec[T],
  row : @protocol.Row,
  missing~ : MissingColumnPolicy = RejectMissing,
) -> T raise MappingError {
  let columns = row.columns_snapshot()
  let values = []
  let budget = [1000000]
  for index, column in columns {
    let path = field_path("$", column.name)
    let value = row.value_at(index) catch {
      _ => raise MappingError(path, InvalidValue)
    }
    check_value(column.typ, value, path, 0, budget)
    values.push(checked_snapshot(column.typ, value, path))
  }
  (self.decode)({ columns, values, missing, }) catch {
    MappingError(path, reason) => raise MappingError(path, reason)
    _ => raise MappingError("$", CallbackFailed)
  }
}

///|
/// 同名列沿用 Row 的首列规则；MissingAsNull 只改变缺列的处理。
pub fn RowReader::column(
  self : RowReader,
  name : String,
) -> ValueReader raise MappingError {
  let path = field_path("$", name)
  for index, column in self.columns {
    if column.name == name {
      return { path, typ: Some(column.typ), value: self.values[index], }
    }
  }
  if self.missing == MissingAsNull {
    return { path, typ: None, value: Null, }
  }
  raise MappingError(path, MissingField)
}
