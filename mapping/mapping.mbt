///|
pub(all) enum MappingReason {
  MissingField
  NullValue
  TypeMismatch
  InvalidValue
  InvalidSchema
  LimitExceeded
  CallbackFailed
} derive(Eq, @debug.Debug)

///|
pub extend MappingReason with Eq::{equal, not_equal}

///|
pub extend MappingReason with @debug.Debug::{to_repr}

///|
pub(all) suberror MappingError {
  MappingError(String, MappingReason)
} derive(@debug.Debug)

///|
pub extend MappingError with @debug.Debug::{to_repr}

///|
fn field_path(parent : String, name : String) -> String {
  "\{parent}[\{Json(name).stringify()}]"
}

///|
fn frozen_type(typ : @types.CqlType) -> @types.CqlType raise MappingError {
  let page = @protocol.Page::new(
    [{ keyspace: "", table: "", name: "value", typ, }],
    [],
  ) catch {
    _ => raise MappingError("$", InvalidSchema)
  }
  page.columns_snapshot()[0].typ
}

///|
// 在交给原有类型／长度校验前定位最深的错误字段，并限制映射遍历规模。
fn check_value(
  typ : @types.CqlType,
  value : @types.Value,
  path : String,
  depth : Int32,
  budget : Array[Int32],
) -> Unit raise MappingError {
  if depth >= 32 || budget[0] <= 0 {
    raise MappingError(path, LimitExceeded)
  }
  budget[0] -= 1
  if value is Unset {
    raise MappingError(path, InvalidValue)
  }
  if value is Null {
    return
  }
  match (typ, value) {
    (Tuple(types), TupleValue(items)) => {
      if types.length() != items.length() {
        raise MappingError(path, TypeMismatch)
      }
      for index, item in items {
        check_value(types[index], item, "\{path}[\{index}]", depth + 1, budget)
      }
    }
    (Udt(_, _, fields), UdtValue(items)) => {
      if fields.length() != items.length() {
        raise MappingError(path, TypeMismatch)
      }
      for index, pair in items {
        let (name, value) = pair
        let child = field_path(path, fields[index].0)
        if fields[index].0 != name {
          raise MappingError(child, TypeMismatch)
        }
        check_value(fields[index].1, value, child, depth + 1, budget)
      }
    }
    (List(item_type), ListValue(items)) | (Set(item_type), SetValue(items)) =>
      for index, item in items {
        let child = "\{path}[\{index}]"
        if item is (Null | Unset) {
          raise MappingError(child, InvalidValue)
        }
        check_value(item_type, item, child, depth + 1, budget)
      }
    (Map(key_type, value_type), MapValue(items)) =>
      for index, pair in items {
        let child = "\{path}[\{index}]"
        if pair.0 is (Null | Unset) {
          raise MappingError(child + ".key", InvalidValue)
        }
        if pair.1 is (Null | Unset) {
          raise MappingError(child + ".value", InvalidValue)
        }
        check_value(key_type, pair.0, child + ".key", depth + 1, budget)
        check_value(value_type, pair.1, child + ".value", depth + 1, budget)
      }
    _ =>
      @types.validate(typ, value) catch {
        _ => raise MappingError(path, TypeMismatch)
      }
  }
}

///|
fn checked_snapshot(
  typ : @types.CqlType,
  value : @types.Value,
  path : String,
) -> @types.Value raise MappingError {
  check_value(typ, value, path, 0, [1000000])
  @types.validate(typ, value) catch {
    _ => raise MappingError(path, InvalidValue)
  }
  @types.snapshot([value])[0] catch {
    _ => raise MappingError(path, LimitExceeded)
  }
}

///|
pub struct EncodeContext {
  path : String
}

///|
pub struct ValueReader {
  path : String
  typ : @types.CqlType?
  value : @types.Value
}

///|
pub struct ValueCodec[T] {
  typ : @types.CqlType
  encode : (T, EncodeContext) -> @types.Value raise
  decode : (ValueReader) -> T raise
  accepts_null : Bool
}

///|
/// 编解码器保存 CQL 类型的独立快照；回调异常不会包含绑定值。
pub fn[T] ValueCodec::new(
  typ : @types.CqlType,
  encode : (T, EncodeContext) -> @types.Value raise,
  decode : (ValueReader) -> T raise,
) -> ValueCodec[T] raise MappingError {
  { typ: frozen_type(typ), encode, decode, accepts_null: false, }
}

///|
/// 返回可供列定义使用的独立类型快照。
pub fn[T] ValueCodec::cql_type(self : ValueCodec[T]) -> @types.CqlType {
  @protocol.columns_snapshot([
    { keyspace: "", table: "", name: "value", typ: self.typ, },
  ])[0].typ
}

///|
/// 调用显式编码器，按声明类型验证并冻结返回值；默认拒绝根 NULL／UNSET。
pub fn[T] ValueCodec::encode(
  self : ValueCodec[T],
  value : T,
) -> @types.Value raise MappingError {
  self.encode_at(value, { path: "$", })
}

///|
fn[T] ValueCodec::encode_at(
  self : ValueCodec[T],
  value : T,
  context : EncodeContext,
) -> @types.Value raise MappingError {
  let encoded = (self.encode)(value, context) catch {
    MappingError(path, reason) => raise MappingError(path, reason)
    _ => raise MappingError(context.path, CallbackFailed)
  }
  if encoded is Null && !self.accepts_null {
    raise MappingError(context.path, NullValue)
  }
  checked_snapshot(self.typ, encoded, context.path)
}

///|
/// 用 UDT 字段路径调用子编码器，使回调错误保留所属字段。
pub fn[T] EncodeContext::field(
  self : EncodeContext,
  name : String,
  codec : ValueCodec[T],
  value : T,
) -> @types.Value raise MappingError {
  codec.encode_at(value, { path: field_path(self.path, name), })
}

///|
/// 用 tuple 元素路径调用子编码器。
pub fn[T] EncodeContext::item(
  self : EncodeContext,
  index : Int32,
  codec : ValueCodec[T],
  value : T,
) -> @types.Value raise MappingError {
  codec.encode_at(value, { path: "\{self.path}[\{index}]", })
}

///|
/// 验证并冻结 Value 后还原应用类型；不会隐式收窄或转换数值。
pub fn[T] ValueCodec::decode(
  self : ValueCodec[T],
  value : @types.Value,
) -> T raise MappingError {
  let value = checked_snapshot(self.typ, value, "$")
  ({ path: "$", typ: Some(self.typ), value, } : ValueReader).read(self)
}

///|
/// 要求实际 CQL 类型与编解码器一致，错误使用当前完整字段路径。
pub fn[T] ValueReader::read(
  self : ValueReader,
  codec : ValueCodec[T],
) -> T raise MappingError {
  if self.typ is Some(typ) && typ != codec.typ {
    raise MappingError(self.path, TypeMismatch)
  }
  if self.value is Null && !codec.accepts_null {
    raise MappingError(self.path, NullValue)
  }
  if self.typ is None && self.value != Null {
    raise MappingError(self.path, InvalidSchema)
  }
  let value = checked_snapshot(codec.typ, self.value, self.path)
  (codec.decode)({ ..self, value, }) catch {
    MappingError(path, reason) => raise MappingError(path, reason)
    _ => raise MappingError(self.path, CallbackFailed)
  }
}

///|
/// 复制已验证的原始 Value，供其他标量或集合的显式转换使用。
pub fn ValueReader::value(
  self : ValueReader,
) -> @types.Value raise MappingError {
  @types.snapshot([self.value])[0] catch {
    _ => raise MappingError(self.path, LimitExceeded)
  }
}

///|
/// 仅 NULL 返回 true；Empty 与空字符串保留各自语义。
pub fn ValueReader::is_null(self : ValueReader) -> Bool {
  self.value is Null
}

///|
/// 按 UDT 声明的字段名读取，缺失字段明确报错。
pub fn ValueReader::field(
  self : ValueReader,
  name : String,
) -> ValueReader raise MappingError {
  let path = field_path(self.path, name)
  guard self.typ is Some(Udt(_, _, types)) && self.value is UdtValue(items) else {
    raise MappingError(path, TypeMismatch)
  }
  for index, pair in types {
    if pair.0 == name {
      guard items.get(index) is Some((_, value)) else {
        raise MappingError(path, MissingField)
      }
      return { path, typ: Some(pair.1), value, }
    }
  }
  raise MappingError(path, MissingField)
}

///|
/// 按 tuple 的零起始下标读取，不补造缺失元素。
pub fn ValueReader::item(
  self : ValueReader,
  index : Int32,
) -> ValueReader raise MappingError {
  let path = "\{self.path}[\{index}]"
  guard self.typ is Some(Tuple(types)) && self.value is TupleValue(items) else {
    raise MappingError(path, TypeMismatch)
  }
  guard types.get(index) is Some(typ) && items.get(index) is Some(value) else {
    raise MappingError(path, MissingField)
  }
  { path, typ: Some(typ), value, }
}

///|
/// 将 NULL 与 None 对应；缺列是否可以视为 NULL 由 RowCodec 单独配置。
pub fn[T] ValueCodec::optional(self : ValueCodec[T]) -> ValueCodec[T?] {
  {
    typ: self.typ,
    accepts_null: true,
    encode: (value, context) => {
      match value {
        None => Null
        Some(value) => self.encode_at(value, context)
      }
    },
    decode: reader => {
      if reader.is_null() {
        None
      } else {
        Some(reader.read(self))
      }
    },
  }
}

///|
/// CQL int 与 MoonBit Int 的精确映射。
pub fn int_codec() -> ValueCodec[Int32] {
  {
    typ: Int,
    accepts_null: false,
    encode: (value, _) => Integer(value),
    decode: reader => {
      match reader.value {
        Integer(value) => value
        _ => raise MappingError(reader.path, TypeMismatch)
      }
    },
  }
}

///|
/// CQL varchar／text 与 String 的映射，其他 CQL 类型需显式创建编解码器。
pub fn text_codec() -> ValueCodec[String] {
  {
    typ: Varchar,
    accepts_null: false,
    encode: (value, _) => Text(value),
    decode: reader => {
      match reader.value {
        Text(value) => value
        _ => raise MappingError(reader.path, TypeMismatch)
      }
    },
  }
}

///|
/// CQL boolean 与 Bool 的映射。
pub fn bool_codec() -> ValueCodec[Bool] {
  {
    typ: Boolean,
    accepts_null: false,
    encode: (value, _) => Boolean(value),
    decode: reader => {
      match reader.value {
        Boolean(value) => value
        _ => raise MappingError(reader.path, TypeMismatch)
      }
    },
  }
}
