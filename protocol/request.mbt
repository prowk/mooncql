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
  keyspace : String?
  now_in_seconds : Int?
  value_names : Array[String]?
  skip_metadata : Bool
  request_options : RequestOptions?
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
  keyspace? : String,
  now_in_seconds? : Int,
  value_names? : Array[String],
  skip_metadata? : Bool = false,
  request_options? : RequestOptions,
) -> QueryOptions {
  {
    consistency,
    page_size,
    paging_state,
    serial_consistency,
    timestamp,
    keyspace,
    now_in_seconds,
    value_names,
    skip_metadata,
    request_options: request_options.map(options => options.snapshot()),
  }
}

///|
pub(all) struct Request {
  opcode : Int
  body : Bytes
  flags : Int
} derive(@debug.Debug)

///|
pub extend Request with @debug.Debug::{to_repr}

///|
pub fn options() -> Request {
  { opcode: 5, body: b"", flags: 0, }
}

///|
pub fn startup(
  compression? : Bool = false,
  throw_on_overload? : Bool = false,
) -> Request raise @codec.CodecError {
  let w = @codec.Writer::new()
  w.u16(
    3 +
    (if compression { 1 } else { 0 }) +
    (if throw_on_overload { 1 } else { 0 }),
  )
  w.string("CQL_VERSION")
  w.string("3.0.0")
  w.string("DRIVER_NAME")
  w.string("mooncql")
  w.string("DRIVER_VERSION")
  w.string("0.1.0")
  if compression {
    w.string("COMPRESSION")
    w.string("lz4")
  }
  if throw_on_overload {
    w.string("THROW_ON_OVERLOAD")
    w.string("1")
  }
  { opcode: 1, body: w.to_bytes(), flags: 0, }
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
  { opcode: 15, body: w.to_bytes(), flags: 0, }
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
  if options.timestamp is Some(ts) && ts < 0L {
    raise @codec.CodecError("negative default timestamp")
  }
  if options.value_names is Some(names) &&
    (names.length() != values.length() || values.is_empty()) {
    raise @codec.CodecError("named values must match nonempty bound values")
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
  if options.skip_metadata {
    flags = flags | 2
  }
  if options.value_names is Some(_) {
    flags = flags | 64
  }
  if options.keyspace is Some(_) {
    flags = flags | 128
  }
  if options.now_in_seconds is Some(_) {
    flags = flags | 256
  }
  w.i32(flags)
  if !values.is_empty() {
    w.u16(values.length())
    for i, value in values {
      if options.value_names is Some(names) {
        w.string(names[i])
      }
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
  if options.keyspace is Some(keyspace) {
    w.string(keyspace)
  }
  if options.now_in_seconds is Some(now) {
    w.i32(now)
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
  decorate(
    { opcode: 7, body: w.to_bytes(), flags: 0, },
    options.request_options,
  )
}

///|
pub fn QueryOptions::snapshot(self : QueryOptions) -> QueryOptions {
  {
    ..self,
    value_names: self.value_names.map(names => names.copy()),
    request_options: self.request_options.map(options => options.snapshot()),
  }
}
