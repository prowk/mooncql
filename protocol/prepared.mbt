///|
pub(all) struct PreparedStatement {
  id : Bytes
  parameters : Array[Column]
  partition_key_indices : Array[Int]
  result_columns : Array[Column]
} derive(@debug.Debug)

///|
pub extend PreparedStatement with @debug.Debug::{to_repr}

///|
pub fn prepare(cql : String) -> Request {
  let w = @codec.Writer::new()
  w.long_string(cql)
  { opcode: 9, body: w.to_bytes(), }
}

///|
pub fn execute(
  id : Bytes,
  values : Array[@types.Value],
  options? : QueryOptions = QueryOptions::new(),
) -> Request raise @codec.CodecError {
  let w = @codec.Writer::new()
  w.short_bytes(id)
  write_parameters(w, values, options)
  { opcode: 10, body: w.to_bytes(), }
}

///|
fn read_prepared(
  r : @codec.Reader,
) -> PreparedStatement raise @codec.CodecError {
  let id = r.short_bytes()
  let flags = r.i32()
  let count = r.i32()
  let pk_count = r.i32()
  if count < 0 ||
    count > 65535 ||
    pk_count < 0 ||
    pk_count > count ||
    (flags & 4) != 0 {
    raise @codec.CodecError("invalid prepared metadata")
  }
  let partition_key_indices = []
  for i = 0; i < pk_count; i = i + 1 {
    let index = r.u16()
    if index >= count || partition_key_indices.contains(index) {
      raise @codec.CodecError("invalid prepared partition key index")
    }
    partition_key_indices.push(index)
  }
  let parameters = read_columns(r, flags, count)
  let result = read_metadata(r)
  { id, parameters, partition_key_indices, result_columns: result.columns, }
}
