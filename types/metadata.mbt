///|
pub fn read_type_limited(
  r : @codec.Reader,
  depth? : Int = 0,
  max_depth? : Int = 32,
) -> CqlType raise @codec.CodecError {
  if max_depth < 1 || max_depth > 32 || depth < 0 || depth >= max_depth {
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
    21 => Duration
    32 => List(read_type_limited(r, depth=depth + 1, max_depth~))
    33 => {
      let key = read_type_limited(r, depth=depth + 1, max_depth~)
      Map(key, read_type_limited(r, depth=depth + 1, max_depth~))
    }
    34 => Set(read_type_limited(r, depth=depth + 1, max_depth~))
    48 => {
      let keyspace = r.string()
      let name = r.string()
      let count = r.u16()
      let fields = []
      for i = 0; i < count; i = i + 1 {
        let field = r.string()
        fields.push((field, read_type_limited(r, depth=depth + 1, max_depth~)))
      }
      Udt(keyspace, name, fields)
    }
    49 => {
      let count = r.u16()
      let fields = []
      for i = 0; i < count; i = i + 1 {
        fields.push(read_type_limited(r, depth=depth + 1, max_depth~))
      }
      Tuple(fields)
    }
    _ => raise @codec.CodecError("unknown CQL type id")
  }
}

///|
pub fn read_type(
  r : @codec.Reader,
  depth? : Int = 0,
) -> CqlType raise @codec.CodecError {
  read_type_limited(r, depth~)
}
