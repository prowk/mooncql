///|
pub(all) enum BatchType {
  Logged
  Unlogged
  Counter
}

///|
pub(all) enum BatchStatement {
  Query(String, Array[@types.Value])
  Prepared(Bytes, Array[@types.Value])
}

///|
pub fn batch(
  statements : Array[BatchStatement],
  kind? : BatchType = Logged,
  options? : QueryOptions = QueryOptions::new(),
) -> Request raise @codec.CodecError {
  if statements.is_empty() ||
    options.page_size is Some(_) ||
    options.paging_state is Some(_) ||
    options.value_names is Some(_) ||
    options.skip_metadata {
    raise @codec.CodecError("invalid batch statements or query-only options")
  }
  let w = @codec.Writer::new()
  w.u8(
    match kind {
      Logged => 0
      Unlogged => 1
      Counter => 2
    },
  )
  w.u16(statements.length())
  for statement in statements {
    let values = match statement {
      Query(cql, values) => {
        w.u8(0)
        w.long_string(cql)
        values
      }
      Prepared(id, values) => {
        w.u8(1)
        w.short_bytes(id)
        values
      }
    }
    w.u16(values.length())
    for value in values {
      @types.write_value(w, value)
    }
  }
  // 空参数列表复用公共选项编码，批处理不允许出现低四位标志。
  write_parameters(w, [], options)
  { opcode: 13, body: w.to_bytes(), }
}
