///|
pub(all) struct Column {
  keyspace : String
  table : String
  name : String
  typ : @types.CqlType
} derive(@debug.Debug)

///|
pub(all) struct Page {
  columns : Array[Column]
  rows : Array[Array[@types.Value]]
  paging_state : Bytes?
  new_metadata_id : Bytes?
  priv schema : ColumnIndex
} derive(@debug.Debug)

///|
pub fn Page::get(
  self : Page,
  row : Int32,
  column : String,
) -> @types.Value raise @codec.CodecError {
  if row < 0 || row >= self.rows.length() {
    raise @codec.CodecError("row index out of range")
  }
  guard self.schema.index(column) is Some(index) else {
    raise @codec.CodecError("unknown column: " + column)
  }
  guard self.rows[row].get(index) is Some(value) else {
    raise @codec.CodecError("row width does not match metadata")
  }
  value
}

///|
pub(all) enum ErrorDetail {
  Other(Bytes)
  Unavailable(Int32, Int32, Int32)
  ReadTimeout(Int32, Int32, Int32, Bool)
  WriteTimeout(Int32, Int32, Int32, String, Int32?)
  ReadFailure(Int32, Int32, Int32, Array[FailureReason], Bool)
  WriteFailure(Int32, Int32, Int32, Array[FailureReason], String)
  FunctionFailure(String, String, Array[String])
  CasWriteUnknown(Int32, Int32, Int32)
  AlreadyExists(String, String)
  Unprepared(Bytes)
} derive(@debug.Debug)

///|
pub(all) struct ServerError {
  code : Int32
  message : String
  detail : ErrorDetail
} derive(@debug.Debug)

///|
pub(all) struct SchemaChange {
  change : String
  target : String
  keyspace : String
  name : String?
  arguments : Array[String]
} derive(@debug.Debug)

///|
pub(all) enum ResultSet {
  Void
  Rows(Page)
  SetKeyspace(String)
  Prepared(PreparedStatement)
  SchemaChanged(SchemaChange)
} derive(@debug.Debug)

///|
pub(all) enum Response {
  Ready
  Authenticate(String)
  AuthChallenge(Bytes?)
  AuthSuccess(Bytes?)
  Supported(Map[String, Array[String]])
  Result(ResultSet)
  Failure(ServerError)
  Event(ServerEvent)
} derive(@debug.Debug)

///|
pub extend Column with @debug.Debug::{to_repr}

///|
pub extend Page with @debug.Debug::{to_repr}

///|
pub extend ErrorDetail with @debug.Debug::{to_repr}

///|
pub extend ServerError with @debug.Debug::{to_repr}

///|
pub extend SchemaChange with @debug.Debug::{to_repr}

///|
pub extend ResultSet with @debug.Debug::{to_repr}

///|
pub extend Response with @debug.Debug::{to_repr}

///|
pub(all) struct Metadata {
  columns : Array[Column]
  paging_state : Bytes?
  new_metadata_id : Bytes?
} derive(@debug.Debug)

///|
pub extend Metadata with @debug.Debug::{to_repr}

///|
fn read_columns(
  r : @codec.Reader,
  flags : Int32,
  count : Int32,
  max_depth~ : Int32 = 32,
) -> Array[Column] raise @codec.CodecError {
  let shared = if (flags & 1) != 0 {
    Some((r.string(), r.string()))
  } else {
    None
  }
  let columns = []
  for i = 0; i < count; i = i + 1 {
    let (keyspace, table) = match shared {
      Some(pair) => pair
      None => (r.string(), r.string())
    }
    let name = r.string()
    columns.push({
      keyspace,
      table,
      name,
      typ: @types.read_type_limited(r, max_depth~),
    })
  }
  columns
}

///|
pub fn read_metadata_limited(
  r : @codec.Reader,
  cached~ : Array[Column] = [],
  max_columns~ : Int32 = 65535,
  max_depth~ : Int32 = 32,
) -> Metadata raise @codec.CodecError {
  if max_depth < 1 || max_depth > 32 {
    raise @codec.CodecError("max_depth must be 1..32")
  }
  let flags = r.i32()
  let count = r.i32()
  if max_columns < 0 || max_columns > 65535 || count < 0 || count > max_columns {
    raise @codec.CodecError("invalid column count")
  }
  let paging_state = if (flags & 2) != 0 {
    let state = r.bytes()
    guard state is Some(_) else {
      raise @codec.CodecError("missing paging state")
    }
    state
  } else {
    None
  }
  if (flags & 12) == 12 {
    raise @codec.CodecError("changed metadata cannot be omitted")
  }
  let new_metadata_id = if (flags & 8) != 0 {
    Some(r.short_bytes())
  } else {
    None
  }
  let columns = if (flags & 4) != 0 {
    if cached.length() != count {
      raise @codec.CodecError("missing cached result metadata")
    }
    let budget = [1000000]
    for column in cached {
      type_size(column.typ, 0, budget, max_depth~)
    }
    cached
  } else {
    read_columns(r, flags, count, max_depth~)
  }
  { columns, paging_state, new_metadata_id, }
}

///|
fn read_schema_change(
  r : @codec.Reader,
) -> SchemaChange raise @codec.CodecError {
  let change = r.string()
  let target = r.string()
  let keyspace = r.string()
  let arguments = []
  let name = match target {
    "KEYSPACE" => None
    "TABLE" | "TYPE" => Some(r.string())
    "FUNCTION" | "AGGREGATE" => {
      let name = r.string()
      let count = r.u16()
      for i = 0; i < count; i = i + 1 {
        arguments.push(r.string())
      }
      Some(name)
    }
    _ => raise @codec.CodecError("unknown schema change target")
  }
  { change, target, keyspace, name, arguments, }
}

///|
pub fn decode_result_limited(
  body : Bytes,
  cached~ : Array[Column] = [],
  max_value_nodes~ : Int32 = 1000000,
  max_rows~ : Int32 = 1000000,
  max_columns~ : Int32 = 65535,
  max_depth~ : Int32 = 32,
) -> ResultSet raise @codec.CodecError {
  if max_rows < 0 ||
    max_rows > 1000000 ||
    max_columns < 0 ||
    max_columns > 65535 {
    raise @codec.CodecError(
      "max_rows must be 0..1000000; max_columns must be 0..65535",
    )
  }
  if max_value_nodes < 1 ||
    max_value_nodes > 1000000 ||
    max_depth < 1 ||
    max_depth > 32 {
    raise @codec.CodecError(
      "max_value_nodes must be 1..1000000; max_depth must be 1..32",
    )
  }
  let r = @codec.Reader::new(body)
  match r.i32() {
    1 => Void
    2 => {
      let budget = @types.DecodeBudget::new_limited(
        max_nodes=max_value_nodes,
        max_depth~,
      )
      let meta = read_metadata_limited(r, cached~, max_columns~, max_depth~)
      let count = r.i32()
      let width = meta.columns.length()
      if count < 0 ||
        count > max_rows ||
        (count > 0 && (width == 0 || count > r.remaining() / 4 / width)) {
        raise @codec.CodecError("invalid row count")
      }
      if count > 0 && count > budget.remaining_nodes() / width {
        raise @codec.CodecError("decoded value node limit exceeded")
      }
      let rows = []
      for i = 0; i < count; i = i + 1 {
        let row = []
        for col in meta.columns {
          row.push(@types.decode_value(col.typ, r.bytes(), budget~))
        }
        rows.push(row)
      }
      Rows(
        Page::new(
          meta.columns,
          rows,
          paging_state=meta.paging_state,
          new_metadata_id=meta.new_metadata_id,
        ),
      )
    }
    3 => SetKeyspace(r.string())
    4 => Prepared(read_prepared(r, max_columns~, max_depth~))
    5 => SchemaChanged(read_schema_change(r))
    _ => raise @codec.CodecError("unknown result kind")
  }
}

///|
pub fn decode_error(body : Bytes) -> ServerError raise @codec.CodecError {
  let r = @codec.Reader::new(body)
  let code = r.i32()
  let message = r.string()
  let detail = match code {
    0x1000 => Unavailable(r.u16(), r.i32(), r.i32())
    0x1100 => {
      let consistency = r.u16()
      let received = r.i32()
      let required = r.i32()
      let kind = r.string()
      let contentions = if kind == "CAS" { Some(r.u16()) } else { None }
      WriteTimeout(consistency, received, required, kind, contentions)
    }
    0x1300 =>
      ReadFailure(r.u16(), r.i32(), r.i32(), read_reasons(r), r.u8() != 0)
    0x1500 =>
      WriteFailure(r.u16(), r.i32(), r.i32(), read_reasons(r), r.string())
    0x1400 => {
      let keyspace = r.string()
      let name = r.string()
      let count = r.u16()
      let arguments = []
      for i = 0; i < count; i = i + 1 {
        arguments.push(r.string())
      }
      FunctionFailure(keyspace, name, arguments)
    }
    0x1700 => CasWriteUnknown(r.u16(), r.i32(), r.i32())
    0x1200 => ReadTimeout(r.u16(), r.i32(), r.i32(), r.u8() != 0)
    0x2400 => AlreadyExists(r.string(), r.string())
    0x2500 => Unprepared(r.short_bytes())
    _ => Other(r.take(r.remaining()))
  }
  { code, message, detail, }
}

///|
pub fn decode_response_limited(
  opcode : Int32,
  body : Bytes,
  cached~ : Array[Column] = [],
  max_value_nodes~ : Int32 = 1000000,
  max_rows~ : Int32 = 1000000,
  max_columns~ : Int32 = 65535,
  max_depth~ : Int32 = 32,
) -> Response raise @codec.CodecError {
  let r = @codec.Reader::new(body)
  match opcode {
    0 => Failure(decode_error(body))
    2 => Ready
    3 => Authenticate(r.string())
    6 => {
      let count = r.u16()
      let result : Map[String, Array[String]] = Map([])
      for i = 0; i < count; i = i + 1 {
        let key = r.string()
        let length = r.u16()
        let values = []
        for j = 0; j < length; j = j + 1 {
          values.push(r.string())
        }
        result[key] = values
      }
      Supported(result)
    }
    8 =>
      Result(
        decode_result_limited(
          body,
          cached~,
          max_value_nodes~,
          max_rows~,
          max_columns~,
          max_depth~,
        ),
      )
    12 => Event(decode_event(body))
    14 => AuthChallenge(r.bytes())
    16 => AuthSuccess(r.bytes())
    _ => raise @codec.CodecError("unexpected response opcode")
  }
}

///|
pub(all) struct FailureReason {
  endpoint : Bytes
  code : Int32
} derive(@debug.Debug)

///|
pub extend FailureReason with @debug.Debug::{to_repr}

///|
fn read_reasons(
  r : @codec.Reader,
) -> Array[FailureReason] raise @codec.CodecError {
  let count = r.i32()
  if count < 0 || count > r.remaining() / 7 {
    raise @codec.CodecError("invalid failure reason map count")
  }
  let reasons = []
  for i = 0; i < count; i = i + 1 {
    let length = r.u8()
    if length != 4 && length != 16 {
      raise @codec.CodecError("invalid failure reason endpoint")
    }
    reasons.push({ endpoint: r.take(length), code: r.u16(), })
  }
  reasons
}

///|
pub fn decode_response(
  opcode : Int32,
  body : Bytes,
  cached~ : Array[Column] = [],
) -> Response raise @codec.CodecError {
  decode_response_limited(opcode, body, cached~)
}

///|
pub fn decode_result(
  body : Bytes,
  cached~ : Array[Column] = [],
  max_value_nodes~ : Int32 = 1000000,
) -> ResultSet raise @codec.CodecError {
  decode_result_limited(body, cached~, max_value_nodes~)
}

///|
pub fn read_metadata(
  r : @codec.Reader,
  cached~ : Array[Column] = [],
) -> Metadata raise @codec.CodecError {
  read_metadata_limited(r, cached~)
}
