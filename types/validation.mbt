///|
pub fn validate(typ : CqlType, value : Value) -> Unit raise @codec.CodecError {
  validate_at(typ, value, 0)
  if value != Null && value != Unset {
    ignore(encode_value(value))
  }
}

///|
fn validate_at(
  typ : CqlType,
  value : Value,
  depth : Int,
) -> Unit raise @codec.CodecError {
  if depth >= 32 {
    raise @codec.CodecError("value nesting exceeds limit")
  }
  let valid = match (typ, value) {
    (_, Null | Unset) => true
    (
      BigInt
      | Counter
      | Boolean
      | Int
      | Double
      | Float
      | Timestamp
      | Uuid
      | TimeUuid
      | Date
      | Time
      | SmallInt
      | TinyInt
      | Inet
      | Decimal
      | VarInt
      | Duration,
      Empty,
    ) => true
    (Ascii, Text(s)) => {
      let mut valid = true
      for b in @utf8.encode(s) {
        if b.to_int() > 127 {
          valid = false
        }
      }
      valid
    }
    (Varchar, Text(_))
    | (BigInt | Counter, BigInteger(_))
    | (Blob, Bytes(_))
    | (Boolean, Boolean(_))
    | (Decimal, Decimal(_, _))
    | (Double, Real(_))
    | (Float, Single(_))
    | (Int, Integer(_))
    | (Timestamp, Timestamp(_))
    | (Uuid | TimeUuid, Uuid(_))
    | (VarInt, VarInt(_))
    | (Inet, Inet(_))
    | (Date, Date(_))
    | (Time, Time(_))
    | (SmallInt, SmallInteger(_))
    | (TinyInt, TinyInteger(_))
    | (Duration, Duration(_, _, _)) => true
    (List(element), ListValue(items)) | (Set(element), SetValue(items)) => {
      for item in items {
        if item == Null || item == Unset {
          raise @codec.CodecError("collection elements cannot be null or unset")
        }
        validate_at(element, item, depth + 1)
      }
      true
    }
    (Map(key_type, value_type), MapValue(items)) => {
      for (key, value) in items {
        if key == Null || key == Unset || value == Null || value == Unset {
          raise @codec.CodecError("map entries cannot be null or unset")
        }
        validate_at(key_type, key, depth + 1)
        validate_at(value_type, value, depth + 1)
      }
      true
    }
    (Tuple(fields), TupleValue(items)) => {
      if fields.length() != items.length() {
        raise @codec.CodecError("tuple arity mismatch")
      }
      for i, item in items {
        if item == Unset {
          raise @codec.CodecError("tuple fields cannot be unset")
        }
        validate_at(fields[i], item, depth + 1)
      }
      true
    }
    (Udt(_, _, fields), UdtValue(items)) => {
      if fields.length() != items.length() {
        raise @codec.CodecError("UDT arity mismatch")
      }
      for i, (name, item) in items {
        let (field_name, field_type) = fields[i]
        if field_name != name || item == Unset {
          raise @codec.CodecError("UDT field mismatch")
        }
        validate_at(field_type, item, depth + 1)
      }
      true
    }
    _ => false
  }
  if !valid {
    raise @codec.CodecError("bound value does not match CQL type")
  }
}
