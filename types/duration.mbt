///|
fn validate_duration(
  months : Int32,
  days : Int32,
  nanos : Int64,
) -> Unit raise @codec.CodecError {
  let negative = months < 0 || days < 0 || nanos < 0L
  let positive = months > 0 || days > 0 || nanos > 0L
  if negative && positive {
    raise @codec.CodecError("duration components must have the same sign")
  }
}

///|
fn write_vint(w : @codec.Writer, value : Int64) -> Unit {
  let unsigned = ((value << 1) ^ (value >> 63)).reinterpret_as_uint64()
  let mut extra = 0
  while extra < 8 && unsigned >> ((extra + 1) * 7) != 0UL {
    extra += 1
  }
  if extra == 8 {
    w.u8(255)
  } else {
    w.u8(((255 << (8 - extra)) & 255) | (unsigned >> (extra * 8)).to_int())
  }
  for i = extra - 1; i >= 0; i = i - 1 {
    w.u8((unsigned >> (i * 8)).to_int())
  }
}

///|
fn read_vint(r : @codec.Reader) -> Int64 raise @codec.CodecError {
  let first = r.u8()
  let mut extra = 0
  while extra < 8 && (first & (128 >> extra)) != 0 {
    extra += 1
  }
  let mut unsigned = (first & (127 >> extra)).to_uint64()
  for i = 0; i < extra; i = i + 1 {
    unsigned = (unsigned << 8) | r.u8().to_uint64()
  }
  (unsigned >> 1).reinterpret_as_int64() ^
  -(unsigned & 1UL).reinterpret_as_int64()
}

///|
fn read_duration(r : @codec.Reader) -> Value raise @codec.CodecError {
  let months = read_vint(r)
  let days = read_vint(r)
  let nanos = read_vint(r)
  if months.to_int().to_int64() != months || days.to_int().to_int64() != days {
    raise @codec.CodecError("duration months or days exceed 32 bits")
  }
  validate_duration(months.to_int(), days.to_int(), nanos)
  Duration(months.to_int(), days.to_int(), nanos)
}
