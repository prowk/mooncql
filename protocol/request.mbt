///|
pub(all) enum Consistency {
  Any
  One
  Two
  Three
  Quorum
  All
  LocalQuorum
  EachQuorum
  Serial
  LocalSerial
  LocalOne
} derive(Eq, @debug.Debug)

///|
pub extend Consistency with Eq::{equal, not_equal}

///|
pub extend Consistency with @debug.Debug::{to_repr}

///|
pub fn Consistency::code(self : Consistency) -> Int {
  match self {
    Any => 0
    One => 1
    Two => 2
    Three => 3
    Quorum => 4
    All => 5
    LocalQuorum => 6
    EachQuorum => 7
    Serial => 8
    LocalSerial => 9
    LocalOne => 10
  }
}

///|
pub(all) struct QueryOptions {
  consistency : Consistency
  page_size : Int?
  paging_state : Bytes?
  serial_consistency : Consistency?
  timestamp : Int64?
} derive(@debug.Debug)

///|
pub extend QueryOptions with @debug.Debug::{to_repr}

///|
pub fn QueryOptions::new(
  consistency? : Consistency = LocalOne,
  page_size? : Int,
  paging_state? : Bytes,
  serial_consistency? : Consistency,
  timestamp? : Int64,
) -> QueryOptions {
  { consistency, page_size, paging_state, serial_consistency, timestamp, }
}

///|
pub(all) struct Request {
  opcode : Int
  body : Bytes
} derive(@debug.Debug)

///|
pub extend Request with @debug.Debug::{to_repr}

///|
pub fn options() -> Request {
  { opcode: 5, body: b"", }
}

///|
pub fn startup() -> Request raise @codec.CodecError {
  let w = @codec.Writer::new()
  w.u16(1)
  w.string("CQL_VERSION")
  w.string("3.0.0")
  { opcode: 1, body: w.to_bytes(), }
}

///|
pub fn password_auth(
  username : String,
  password : String,
) -> Request raise @codec.CodecError {
  let user = @utf8.encode(username)
  let pass = @utf8.encode(password)
  for b in user {
    if b == b'\x00' {
      raise @codec.CodecError("NUL in username")
    }
  }
  for b in pass {
    if b == b'\x00' {
      raise @codec.CodecError("NUL in password")
    }
  }
  let token = @codec.Writer::new()
  token.u8(0)
  token.raw(user)
  token.u8(0)
  token.raw(pass)
  let w = @codec.Writer::new()
  w.bytes(Some(token.to_bytes()))
  { opcode: 15, body: w.to_bytes(), }
}

///|
fn write_parameters(
  w : @codec.Writer,
  values : Array[@types.Value],
  options : QueryOptions,
) -> Unit raise @codec.CodecError {
  if options.page_size is Some(size) && size <= 0 {
    raise @codec.CodecError("page size must be positive")
  }
  if options.serial_consistency is Some(c) && c != Serial && c != LocalSerial {
    raise @codec.CodecError("invalid serial consistency")
  }
  if options.consistency == Serial || options.consistency == LocalSerial {
    raise @codec.CodecError(
      "serial consistency belongs in serial_consistency option",
    )
  }
  w.u16(options.consistency.code())
  let mut flags = if values.is_empty() { 0 } else { 1 }
  if options.page_size is Some(_) {
    flags = flags | 4
  }
  if options.paging_state is Some(_) {
    flags = flags | 8
  }
  if options.serial_consistency is Some(_) {
    flags = flags | 16
  }
  if options.timestamp is Some(_) {
    flags = flags | 32
  }
  w.u8(flags)
  if !values.is_empty() {
    w.u16(values.length())
    for value in values {
      @types.write_value(w, value)
    }
  }
  if options.page_size is Some(size) {
    w.i32(size)
  }
  if options.paging_state is Some(state) {
    w.bytes(Some(state))
  }
  if options.serial_consistency is Some(c) {
    w.u16(c.code())
  }
  if options.timestamp is Some(ts) {
    w.i64(ts)
  }
}

///|
pub fn query(
  cql : String,
  values? : Array[@types.Value] = [],
  options? : QueryOptions = QueryOptions::new(),
) -> Request raise @codec.CodecError {
  let w = @codec.Writer::new()
  w.long_string(cql)
  write_parameters(w, values, options)
  { opcode: 7, body: w.to_bytes(), }
}
