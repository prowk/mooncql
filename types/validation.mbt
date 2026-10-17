///|
pub fn validate(typ : CqlType, value : Value) -> Unit raise @codec.CodecError {
  let valid = match (typ, value) {
    (_, Null | Unset) => true
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
    | (TinyInt, TinyInteger(_)) => true
    _ => false
  }
  if !valid {
    raise @codec.CodecError("bound value does not match CQL type")
  }
  if value != Null && value != Unset {
    ignore(encode_scalar(value))
  }
}
