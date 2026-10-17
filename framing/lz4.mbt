///|
fn extension(w : @codec.Writer, length : Int) -> Unit {
  let mut remaining = length
  while remaining >= 255 {
    w.u8(255)
    remaining -= 255
  }
  w.u8(remaining)
}

///|
fn hash4(bytes : Bytes, offset : Int) -> Int {
  let value = bytes[offset].to_int() |
    (bytes[offset + 1].to_int() << 8) |
    (bytes[offset + 2].to_int() << 16) |
    (bytes[offset + 3].to_int() << 24)
  ((value.reinterpret_as_uint() * 2654435761U) >> 16).reinterpret_as_int()
}

///|
pub fn lz4_compress(bytes : Bytes) -> Bytes {
  let table = Array::make(65536, -1)
  let w = @codec.Writer::new()
  let mut anchor = 0
  let mut position = 0
  // 最后一次匹配距结尾至少十二字节，结尾保留至少五个字面量。
  while position <= bytes.length() - 12 {
    let hash = hash4(bytes, position)
    let previous = table[hash]
    table[hash] = position
    if previous < 0 ||
      position - previous > 65535 ||
      bytes[previous:previous + 4] != bytes[position:position + 4] {
      position += 1
      continue
    }
    let mut length = 4
    while position + length < bytes.length() - 5 &&
          bytes[previous + length] == bytes[position + length] {
      length += 1
    }
    let literals = position - anchor
    w.u8(
      ((if literals < 15 { literals } else { 15 }) << 4) |
      (if length - 4 < 15 { length - 4 } else { 15 }),
    )
    if literals >= 15 {
      extension(w, literals - 15)
    }
    w.raw(bytes[anchor:position].to_owned())
    let distance = position - previous
    w.u8(distance)
    w.u8(distance >> 8)
    if length - 4 >= 15 {
      extension(w, length - 19)
    }
    position += length
    anchor = position
  }
  let literals = bytes.length() - anchor
  w.u8((if literals < 15 { literals } else { 15 }) << 4)
  if literals >= 15 {
    extension(w, literals - 15)
  }
  w.raw(bytes[anchor:].to_owned())
  w.to_bytes()
}

///|
fn read_length(
  r : @codec.Reader,
  base : Int,
  limit : Int,
) -> Int raise @codec.CodecError {
  let mut length = base
  if base == 15 {
    let mut next = 255
    while next == 255 {
      next = r.u8()
      if length > limit - next {
        raise @codec.CodecError("LZ4 length exceeds output limit")
      }
      length += next
    }
  }
  if length > limit {
    raise @codec.CodecError("LZ4 length exceeds output limit")
  }
  length
}

///|
pub fn lz4_decompress(
  bytes : Bytes,
  expected : Int,
) -> Bytes raise @codec.CodecError {
  if expected < 0 || expected > 131071 {
    raise @codec.CodecError("invalid LZ4 output length")
  }
  let r = @codec.Reader::new(bytes)
  let output : Array[Byte] = []
  while r.remaining() > 0 {
    let token = r.u8()
    let literals = read_length(r, token >> 4, expected - output.length())
    for byte in r.take(literals) {
      output.push(byte)
    }
    if r.remaining() == 0 {
      break
    }
    let low = r.u8()
    let distance = low | (r.u8() << 8)
    if distance == 0 || distance > output.length() {
      raise @codec.CodecError("invalid LZ4 match offset")
    }
    let available = expected - output.length()
    if available < 4 {
      raise @codec.CodecError("LZ4 match exceeds output limit")
    }
    let length = read_length(r, token & 15, available - 4) + 4
    for i = 0; i < length; i = i + 1 {
      // 逐字节读取新输出，支持匹配源与目标重叠。
      output.push(output[output.length() - distance])
    }
  }
  if output.length() != expected {
    raise @codec.CodecError("LZ4 output length mismatch")
  }
  Bytes::from_array(output)
}
