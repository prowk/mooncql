///|
pub(all) struct PreparedStatement {
  id : Bytes
  result_metadata_id : Bytes
  parameters : Array[Column]
  partition_key_indices : Array[Int32]
  result_columns : Array[Column]
} derive(@debug.Debug)

///|
pub extend PreparedStatement with @debug.Debug::{to_repr}

///|
pub fn prepare(
  cql : String,
  keyspace? : String,
  request_options? : RequestOptions,
) -> Request raise @codec.CodecError {
  let w = @codec.Writer::new()
  w.long_string(cql)
  w.i32(if keyspace is Some(_) { 1 } else { 0 })
  if keyspace is Some(name) {
    w.string(name)
  }
  decorate({ opcode: 9, body: w.to_bytes(), flags: 0, }, request_options)
}

///|
pub fn execute(
  id : Bytes,
  result_metadata_id : Bytes,
  values : Array[@types.Value],
  options~ : QueryOptions = QueryOptions::new(),
) -> Request raise @codec.CodecError {
  let w = @codec.Writer::new()
  w.short_bytes(id)
  w.short_bytes(result_metadata_id)
  write_parameters(w, values, options)
  decorate(
    { opcode: 10, body: w.to_bytes(), flags: 0, },
    options.request_options,
  )
}

///|
fn read_prepared(
  r : @codec.Reader,
  max_columns~ : Int32 = 65535,
  max_depth~ : Int32 = 32,
) -> PreparedStatement raise @codec.CodecError {
  let id = r.short_bytes()
  let result_metadata_id = r.short_bytes()
  let flags = r.i32()
  let count = r.i32()
  let pk_count = r.i32()
  if count < 0 ||
    count > max_columns ||
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
  let parameters = read_columns(r, flags, count, max_depth~)
  let result = read_metadata_limited(r, max_columns~, max_depth~)
  {
    id,
    result_metadata_id,
    parameters,
    partition_key_indices,
    result_columns: result.columns,
  }
}
