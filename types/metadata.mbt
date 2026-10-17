///|
pub fn read_type(
  r : @codec.Reader,
  depth? : Int = 0,
) -> CqlType raise @codec.CodecError {
  if depth >= 32 {
    raise @codec.CodecError("type nesting exceeds limit")
  }
  match r.u16() {
    0 => Custom(r.string())
    1 => Ascii
    2 => BigInt
    3 => Blob
    4 => Boolean
    5 => Counter
    6 => Decimal
    7 => Double
    8 => Float
    9 => Int
    10 | 13 => Varchar
    11 => Timestamp
    12 => Uuid
    14 => VarInt
    15 => TimeUuid
    16 => Inet
    17 => Date
    18 => Time
    19 => SmallInt
    20 => TinyInt
    32 => List(read_type(r, depth=depth + 1))
    33 => {
      let key = read_type(r, depth=depth + 1)
      Map(key, read_type(r, depth=depth + 1))
    }
    34 => Set(read_type(r, depth=depth + 1))
    48 => {
      let keyspace = r.string()
      let name = r.string()
      let count = r.u16()
      let fields = []
      for i = 0; i < count; i = i + 1 {
        let field = r.string()
        fields.push((field, read_type(r, depth=depth + 1)))
      }
      Udt(keyspace, name, fields)
    }
    49 => {
      let count = r.u16()
      let fields = []
      for i = 0; i < count; i = i + 1 {
        fields.push(read_type(r, depth=depth + 1))
      }
      Tuple(fields)
    }
    _ => raise @codec.CodecError("unknown CQL type id")
  }
}
