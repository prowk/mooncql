///|
struct ColumnIndex {
  columns : Array[Column]
  mut lookup : Map[String, Int]?
}

///|
impl @debug.Debug for ColumnIndex with fn to_repr(_) {
  @debug.Repr("column index")
}

///|
fn ColumnIndex::index(self : ColumnIndex, name : String) -> Int? {
  let lookup = match self.lookup {
    Some(value) => value
    None => {
      let value : Map[String, Int] = Map([])
      for i, column in self.columns {
        if !value.contains(column.name) {
          value[column.name] = i
        }
      }
      self.lookup = Some(value)
      value
    }
  }
  lookup.get(name)
}

///|
fn copy_type(typ : @types.CqlType) -> @types.CqlType {
  match typ {
    List(item) => List(copy_type(item))
    Set(item) => Set(copy_type(item))
    Map(key, value) => Map(copy_type(key), copy_type(value))
    Tuple(items) => Tuple(items.map(copy_type))
    Udt(ks, name, fields) =>
      Udt(
        ks,
        name,
        fields.map(pair => {
          let (name, typ) = pair
          (name, copy_type(typ))
        }),
      )
    _ => typ
  }
}

///|
fn type_size(
  typ : @types.CqlType,
  depth : Int,
  budget : Array[Int],
) -> Unit raise @codec.CodecError {
  if depth >= 32 || budget[0] <= 0 {
    raise @codec.CodecError("row metadata exceeds snapshot limit")
  }
  budget[0] -= 1
  match typ {
    List(item) | Set(item) => type_size(item, depth + 1, budget)
    Map(key, value) => {
      type_size(key, depth + 1, budget)
      type_size(value, depth + 1, budget)
    }
    Tuple(items) =>
      for item in items {
        type_size(item, depth + 1, budget)
      }
    Udt(_, _, fields) =>
      for pair in fields {
        type_size(pair.1, depth + 1, budget)
      }
    _ => ()
  }
}

///|
fn copy_columns(columns : Array[Column]) -> Array[Column] {
  columns.map(column => { ..column, typ: copy_type(column.typ), })
}

///|
pub fn Page::new(
  columns : Array[Column],
  rows : Array[Array[@types.Value]],
  paging_state? : Bytes? = None,
  new_metadata_id? : Bytes? = None,
) -> Page raise @codec.CodecError {
  if columns.length() > 65535 {
    raise @codec.CodecError("too many columns")
  }
  let budget = [1000000]
  for column in columns {
    type_size(column.typ, 0, budget)
  }
  for row in rows {
    if row.length() != columns.length() {
      raise @codec.CodecError("row width does not match metadata")
    }
  }
  let schema = { columns: copy_columns(columns), lookup: None, }
  {
    columns: copy_columns(schema.columns),
    rows,
    paging_state,
    new_metadata_id,
    schema,
  }
}

///|
pub fn Page::columns_snapshot(self : Page) -> Array[Column] {
  copy_columns(self.schema.columns)
}

///|
pub(all) suberror RowError {
  MissingColumn(String, String)
  NullColumn(String, String)
  TypeMismatch(String, String, String)
  InvalidRow(String)
} derive(@debug.Debug)

///|
pub extend RowError with @debug.Debug::{to_repr}

///|
pub struct Row {
  schema : ColumnIndex
  values : Array[@types.Value]
} derive(@debug.Debug)

///|
pub extend Row with @debug.Debug::{to_repr}

///|
pub fn Page::row(self : Page, index : Int) -> Row raise RowError {
  guard self.rows.get(index) is Some(values) else {
    raise InvalidRow("row index out of range")
  }
  { schema: self.schema, values, }
}

///|
fn type_name(typ : @types.CqlType) -> String {
  match typ {
    Ascii => "ascii"
    Varchar => "varchar"
    BigInt => "bigint"
    Counter => "counter"
    Int => "int"
    SmallInt => "smallint"
    TinyInt => "tinyint"
    Boolean => "boolean"
    Double => "double"
    Float => "float"
    Blob => "blob"
    Uuid => "uuid"
    TimeUuid => "timeuuid"
    Date => "date"
    Time => "time"
    Timestamp => "timestamp"
    Decimal => "decimal"
    VarInt => "varint"
    Inet => "inet"
    Duration => "duration"
    List(_) => "list"
    Set(_) => "set"
    Map(_, _) => "map"
    Tuple(_) => "tuple"
    Udt(ks, name, _) => "udt<\{ks}.\{name}>"
    Custom(name) => "custom<\{name}>"
  }
}

///|
fn Row::lookup(
  self : Row,
  name : String,
  expected : String,
  allow_null? : Bool = false,
) -> (@types.CqlType, @types.Value) raise RowError {
  guard self.schema.index(name) is Some(index) else {
    raise MissingColumn(name, expected)
  }
  guard self.values.get(index) is Some(value) else {
    raise InvalidRow(
      "row width does not match metadata for " +
      name +
      " (expected " +
      expected +
      ")",
    )
  }
  if !allow_null && value is Null {
    raise NullColumn(name, expected)
  }
  (self.schema.columns[index].typ, value)
}

///|
pub fn Row::value(self : Row, name : String) -> @types.Value raise RowError {
  self.lookup(name, "Value", allow_null=true).1
}

///|
pub fn Row::value_at(self : Row, index : Int) -> @types.Value raise RowError {
  if index < 0 || index >= self.schema.columns.length() {
    raise InvalidRow("column index out of range")
  }
  guard self.values.get(index) is Some(value) else {
    raise InvalidRow("row width does not match metadata")
  }
  value
}

///|
pub fn Row::columns_snapshot(self : Row) -> Array[Column] {
  copy_columns(self.schema.columns)
}

///|
pub fn Row::is_null(self : Row, name : String) -> Bool raise RowError {
  self.value(name) is Null
}

///|
pub fn Row::text(self : Row, name : String) -> String raise RowError {
  let (typ, value) = self.lookup(name, "text")
  match (typ, value) {
    (Ascii | Varchar, Text(value)) => value
    _ => raise TypeMismatch(name, "text", type_name(typ))
  }
}

///|
pub fn Row::int(self : Row, name : String) -> Int raise RowError {
  let (typ, value) = self.lookup(name, "int")
  match (typ, value) {
    (Int, Integer(value))
    | (SmallInt, SmallInteger(value))
    | (TinyInt, TinyInteger(value)) => value
    _ => raise TypeMismatch(name, "int", type_name(typ))
  }
}

///|
pub fn Row::int64(self : Row, name : String) -> Int64 raise RowError {
  let (typ, value) = self.lookup(name, "int64")
  match (typ, value) {
    (BigInt | Counter, BigInteger(value)) => value
    (Int, Integer(value))
    | (SmallInt, SmallInteger(value))
    | (TinyInt, TinyInteger(value)) => value.to_int64()
    _ => raise TypeMismatch(name, "int64", type_name(typ))
  }
}

///|
pub fn Row::boolean(self : Row, name : String) -> Bool raise RowError {
  let (typ, value) = self.lookup(name, "boolean")
  match (typ, value) {
    (Boolean, Boolean(value)) => value
    _ => raise TypeMismatch(name, "boolean", type_name(typ))
  }
}

///|
pub fn Row::double(self : Row, name : String) -> Double raise RowError {
  let (typ, value) = self.lookup(name, "double")
  match (typ, value) {
    (Double, Real(value)) => value
    _ => raise TypeMismatch(name, "double", type_name(typ))
  }
}

///|
pub fn Row::float(self : Row, name : String) -> Float raise RowError {
  let (typ, value) = self.lookup(name, "float")
  match (typ, value) {
    (Float, Single(value)) => value
    _ => raise TypeMismatch(name, "float", type_name(typ))
  }
}

///|
pub fn Row::bytes(self : Row, name : String) -> Bytes raise RowError {
  let (typ, value) = self.lookup(name, "bytes")
  match (typ, value) {
    (Blob, Bytes(value)) => value
    _ => raise TypeMismatch(name, "bytes", type_name(typ))
  }
}

///|
pub fn Row::inet(self : Row, name : String) -> Bytes raise RowError {
  let (typ, value) = self.lookup(name, "inet")
  match (typ, value) {
    (Inet, Inet(value)) => value
    _ => raise TypeMismatch(name, "inet", type_name(typ))
  }
}

///|
pub fn Row::uuid(self : Row, name : String) -> @types.CqlUuid raise RowError {
  let (typ, value) = self.lookup(name, "uuid")
  match (typ, value) {
    (Uuid | TimeUuid, Uuid(value)) =>
      @types.CqlUuid::from_bytes(value) catch {
        _ => raise TypeMismatch(name, "uuid", "invalid " + type_name(typ))
      }
    _ => raise TypeMismatch(name, "uuid", type_name(typ))
  }
}

///|
pub fn Row::date(self : Row, name : String) -> @types.CqlDate raise RowError {
  let (typ, value) = self.lookup(name, "date")
  match (typ, value) {
    (Date, Date(value)) => @types.CqlDate::from_days(value)
    _ => raise TypeMismatch(name, "date", type_name(typ))
  }
}

///|
pub fn Row::time(self : Row, name : String) -> @types.CqlTime raise RowError {
  let (typ, value) = self.lookup(name, "time")
  match (typ, value) {
    (Time, Time(value)) =>
      @types.CqlTime::from_nanos(value) catch {
        _ => raise TypeMismatch(name, "time", "invalid " + type_name(typ))
      }
    _ => raise TypeMismatch(name, "time", type_name(typ))
  }
}

///|
pub fn Row::timestamp(
  self : Row,
  name : String,
) -> @types.CqlTimestamp raise RowError {
  let (typ, value) = self.lookup(name, "timestamp")
  match (typ, value) {
    (Timestamp, Timestamp(value)) => @types.CqlTimestamp::from_millis(value)
    _ => raise TypeMismatch(name, "timestamp", type_name(typ))
  }
}

///|
pub fn Row::decimal(
  self : Row,
  name : String,
) -> @types.CqlDecimal raise RowError {
  let (typ, value) = self.lookup(name, "decimal")
  match (typ, value) {
    (Decimal, Decimal(scale, value)) =>
      @types.CqlDecimal::from_parts(scale, value) catch {
        _ => raise TypeMismatch(name, "decimal", "invalid " + type_name(typ))
      }
    _ => raise TypeMismatch(name, "decimal", type_name(typ))
  }
}

///|
pub fn Row::varint(
  self : Row,
  name : String,
) -> @types.CqlVarInt raise RowError {
  let (typ, value) = self.lookup(name, "varint")
  match (typ, value) {
    (VarInt, VarInt(value)) =>
      @types.CqlVarInt::from_bytes(value) catch {
        _ => raise TypeMismatch(name, "varint", "invalid " + type_name(typ))
      }
    _ => raise TypeMismatch(name, "varint", type_name(typ))
  }
}

///|
pub fn Row::duration(
  self : Row,
  name : String,
) -> (Int, Int, Int64) raise RowError {
  let (typ, value) = self.lookup(name, "duration")
  match (typ, value) {
    (Duration, Duration(months, days, nanos)) => (months, days, nanos)
    _ => raise TypeMismatch(name, "duration", type_name(typ))
  }
}

///|
pub fn Row::list(
  self : Row,
  name : String,
) -> Array[@types.Value] raise RowError {
  let (typ, value) = self.lookup(name, "list")
  match (typ, value) {
    (List(_), ListValue(value)) => value
    _ => raise TypeMismatch(name, "list", type_name(typ))
  }
}

///|
pub fn Row::set(
  self : Row,
  name : String,
) -> Array[@types.Value] raise RowError {
  let (typ, value) = self.lookup(name, "set")
  match (typ, value) {
    (Set(_), SetValue(value)) => value
    _ => raise TypeMismatch(name, "set", type_name(typ))
  }
}

///|
pub fn Row::map(
  self : Row,
  name : String,
) -> Array[(@types.Value, @types.Value)] raise RowError {
  let (typ, value) = self.lookup(name, "map")
  match (typ, value) {
    (Map(_, _), MapValue(value)) => value
    _ => raise TypeMismatch(name, "map", type_name(typ))
  }
}

///|
pub fn Row::tuple(
  self : Row,
  name : String,
) -> Array[@types.Value] raise RowError {
  let (typ, value) = self.lookup(name, "tuple")
  match (typ, value) {
    (Tuple(_), TupleValue(value)) => value
    _ => raise TypeMismatch(name, "tuple", type_name(typ))
  }
}

///|
pub fn Row::udt(
  self : Row,
  name : String,
) -> Array[(String, @types.Value)] raise RowError {
  let (typ, value) = self.lookup(name, "udt")
  match (typ, value) {
    (Udt(_, _, _), UdtValue(value)) => value
    _ => raise TypeMismatch(name, "udt", type_name(typ))
  }
}
