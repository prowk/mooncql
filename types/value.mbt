///|
pub(all) enum CqlType {
  Ascii
  BigInt
  Blob
  Boolean
  Counter
  Decimal
  Double
  Float
  Int
  Timestamp
  Uuid
  Varchar
  VarInt
  TimeUuid
  Inet
  Date
  Time
  SmallInt
  TinyInt
  Duration
  List(CqlType)
  Set(CqlType)
  Map(CqlType, CqlType)
  Tuple(Array[CqlType])
  Udt(String, String, Array[(String, CqlType)])
  Custom(String)
} derive(Eq, @debug.Debug)

///|
pub(all) enum Value {
  Null
  Unset
  Text(String)
  Integer(Int)
  BigInteger(Int64)
  Bytes(Bytes)
  Boolean(Bool)
  Real(Double)
  Single(Float)
  Uuid(Bytes)
  Timestamp(Int64)
  Date(Int)
  Time(Int64)
  SmallInteger(Int)
  TinyInteger(Int)
  Inet(Bytes)
  Decimal(Int, Bytes)
  VarInt(Bytes)
  Duration(Int, Int, Int64)
  ListValue(Array[Value])
  SetValue(Array[Value])
  MapValue(Array[(Value, Value)])
  TupleValue(Array[Value])
  UdtValue(Array[(String, Value)])
} derive(Eq, @debug.Debug)

///|
pub extend CqlType with Eq::{equal, not_equal}

///|
pub extend CqlType with @debug.Debug::{to_repr}

///|
pub extend Value with Eq::{equal, not_equal}

///|
pub extend Value with @debug.Debug::{to_repr}

///|
pub fn encode_scalar(value : Value) -> Bytes raise @codec.CodecError {
  let w = @codec.Writer::new()
  match value {
    ListValue(_) | SetValue(_) | MapValue(_) | TupleValue(_) | UdtValue(_) =>
      raise @codec.CodecError("expected scalar value")
    Null | Unset =>
      raise @codec.CodecError("null and unset have no scalar payload")
    Text(s) => w.raw(@utf8.encode(s))
    Integer(n) => w.i32(n)
    BigInteger(n) | Timestamp(n) => w.i64(n)
    Bytes(b) => w.raw(b)
    Boolean(b) => w.u8(if b { 1 } else { 0 })
    Real(n) => w.i64(n.reinterpret_as_int64())
    Single(n) => w.i32(n.reinterpret_as_int())
    Uuid(b) => {
      if b.length() != 16 {
        raise @codec.CodecError("UUID must contain 16 bytes")
      }
      w.raw(b)
    }
    Date(days) => w.i32(days ^ -2147483648)
    Time(ns) => {
      if ns < 0L || ns >= 86400000000000L {
        raise @codec.CodecError("time outside day")
      }
      w.i64(ns)
    }
    SmallInteger(n) => {
      if n < -32768 || n > 32767 {
        raise @codec.CodecError("smallint out of range")
      }
      w.u16(n & 65535)
    }
    TinyInteger(n) => {
      if n < -128 || n > 127 {
        raise @codec.CodecError("tinyint out of range")
      }
      w.u8(n)
    }
    Inet(b) => {
      if b.length() != 4 && b.length() != 16 {
        raise @codec.CodecError("inet must contain 4 or 16 bytes")
      }
      w.raw(b)
    }
    Decimal(scale, unscaled) => {
      if unscaled.length() == 0 {
        raise @codec.CodecError("empty decimal integer")
      }
      w.i32(scale)
      w.raw(unscaled)
    }
    Duration(months, days, nanos) => {
      validate_duration(months, days, nanos)
      write_vint(w, months.to_int64())
      write_vint(w, days.to_int64())
      write_vint(w, nanos)
    }
    VarInt(b) => {
      if b.length() == 0 {
        raise @codec.CodecError("empty varint")
      }
      w.raw(b)
    }
  }
  w.to_bytes()
}

///|
pub fn write_value(
  w : @codec.Writer,
  value : Value,
) -> Unit raise @codec.CodecError {
  match value {
    Null => w.i32(-1)
    Unset => w.i32(-2)
    _ => w.bytes(Some(encode_value(value)))
  }
}

///|
pub fn decode_value(
  typ : CqlType,
  bytes : Bytes?,
) -> Value raise @codec.CodecError {
  decode_value_at(typ, bytes, 0)
}

///|
fn decode_value_at(
  typ : CqlType,
  bytes : Bytes?,
  depth : Int,
) -> Value raise @codec.CodecError {
  if depth >= 32 {
    raise @codec.CodecError("value nesting exceeds limit")
  }
  guard bytes is Some(data) else { return Null }
  let r = @codec.Reader::new(data)
  let value = match typ {
    Ascii | Varchar => {
      if typ == Ascii {
        for byte in data {
          if byte.to_int() > 127 {
            raise @codec.CodecError("non-ASCII byte")
          }
        }
      }
      let s = @utf8.decode(r.take(r.remaining())) catch {
        _ => raise @codec.CodecError("invalid text UTF-8")
      }
      Text(s)
    }
    BigInt | Counter => BigInteger(r.i64())
    Blob => Bytes(r.take(r.remaining()))
    Boolean => {
      let b = r.u8()
      if b != 0 && b != 1 {
        raise @codec.CodecError("invalid boolean")
      }
      Boolean(b == 1)
    }
    Int => Integer(r.i32())
    Double => Real(r.i64().reinterpret_as_double())
    Float => Single(Float::reinterpret_from_int(r.i32()))
    Timestamp => Timestamp(r.i64())
    Uuid | TimeUuid => Uuid(r.take(16))
    Date => Date(r.i32() ^ -2147483648)
    Time => {
      let n = r.i64()
      if n < 0L || n >= 86400000000000L {
        raise @codec.CodecError("time outside day")
      }
      Time(n)
    }
    SmallInt => {
      let n = r.u16()
      SmallInteger(if n >= 32768 { n - 65536 } else { n })
    }
    TinyInt => {
      let n = r.u8()
      TinyInteger(if n >= 128 { n - 256 } else { n })
    }
    Inet => {
      let b = r.take(r.remaining())
      if b.length() != 4 && b.length() != 16 {
        raise @codec.CodecError("invalid inet length")
      }
      Inet(b)
    }
    Decimal => {
      let scale = r.i32()
      let unscaled = r.take(r.remaining())
      if unscaled.length() == 0 {
        raise @codec.CodecError("empty decimal integer")
      }
      Decimal(scale, unscaled)
    }
    VarInt => {
      let b = r.take(r.remaining())
      if b.length() == 0 {
        raise @codec.CodecError("empty varint")
      }
      VarInt(b)
    }
    Duration => read_duration(r)
    List(_) | Set(_) | Map(_, _) | Tuple(_) | Udt(_, _, _) =>
      decode_composite(typ, r, depth)
    Custom(_) => raise @codec.CodecError("custom CQL types are unsupported")
  }
  r.finish()
  value
}
