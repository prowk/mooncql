///|
pub(all) suberror CodecError {
  CodecError(String)
} derive(@debug.Debug)

///|
pub extend CodecError with @debug.Debug::{to_repr}

///|
pub struct Reader {
  data : Bytes
  mut offset : Int32
}

///|
pub fn Reader::new(data : Bytes) -> Reader {
  { data, offset: 0, }
}

///|
pub fn Reader::remaining(self : Reader) -> Int32 {
  self.data.length() - self.offset
}

///|
pub fn Reader::take(self : Reader, length : Int32) -> Bytes raise CodecError {
  // 先比较剩余长度，避免偏移加法溢出及越界切片。
  if length < 0 || length > self.remaining() {
    raise CodecError("truncated or invalid byte length")
  }
  let start = self.offset
  self.offset += length
  self.data[start:start + length].to_owned()
}

///|
pub fn Reader::u8(self : Reader) -> Int32 raise CodecError {
  self.take(1)[0].to_int()
}

///|
pub fn Reader::u16(self : Reader) -> Int32 raise CodecError {
  let b = self.take(2)
  (b[0].to_int() << 8) | b[1].to_int()
}

///|
pub fn Reader::i32(self : Reader) -> Int32 raise CodecError {
  let b = self.take(4)
  (b[0].to_int() << 24) |
  (b[1].to_int() << 16) |
  (b[2].to_int() << 8) |
  b[3].to_int()
}

///|
pub fn Reader::i64(self : Reader) -> Int64 raise CodecError {
  let b = self.take(8)
  let mut value = 0L
  for byte in b {
    value = (value << 8) | byte.to_int().to_int64()
  }
  value
}

///|
pub fn Reader::string(self : Reader) -> String raise CodecError {
  let length = self.u16()
  let bytes = self.take(length)
  @utf8.decode(bytes) catch {
    _ => raise CodecError("invalid UTF-8 string")
  }
}

///|
pub fn Reader::long_string(self : Reader) -> String raise CodecError {
  let length = self.i32()
  let bytes = self.take(length)
  @utf8.decode(bytes) catch {
    _ => raise CodecError("invalid UTF-8 long string")
  }
}

///|
pub fn Reader::short_bytes(self : Reader) -> Bytes raise CodecError {
  let length = self.u16()
  self.take(length)
}

///|
pub fn Reader::bytes(self : Reader) -> Bytes? raise CodecError {
  let length = self.i32()
  if length == -1 {
    None
  } else {
    Some(self.take(length))
  }
}

///|
pub fn Reader::finish(self : Reader) -> Unit raise CodecError {
  if self.remaining() != 0 {
    raise CodecError("unexpected trailing bytes")
  }
}

///|
pub struct Writer {
  buffer : @buffer.Buffer
}

///|
pub fn Writer::new() -> Writer {
  { buffer: @buffer.Buffer(), }
}

///|
pub fn Writer::raw(self : Writer, value : Bytes) -> Unit {
  self.buffer.write_bytes(value)
}

///|
pub fn Writer::u8(self : Writer, value : Int32) -> Unit {
  self.buffer.write_byte(value.to_byte())
}

///|
pub fn Writer::u16(self : Writer, value : Int32) -> Unit raise CodecError {
  if value < 0 || value > 65535 {
    raise CodecError("unsigned short out of range")
  }
  self.u8(value >> 8)
  self.u8(value)
}

///|
pub fn Writer::i32(self : Writer, value : Int32) -> Unit {
  self.u8(value >> 24)
  self.u8(value >> 16)
  self.u8(value >> 8)
  self.u8(value)
}

///|
pub fn Writer::i64(self : Writer, value : Int64) -> Unit {
  for i = 7; i >= 0; i = i - 1 {
    self.u8((value >> (i * 8)).to_int())
  }
}

///|
pub fn Writer::string(self : Writer, value : String) -> Unit raise CodecError {
  let bytes = @utf8.encode(value)
  self.u16(bytes.length())
  self.raw(bytes)
}

///|
pub fn Writer::long_string(self : Writer, value : String) -> Unit {
  let bytes = @utf8.encode(value)
  self.i32(bytes.length())
  self.raw(bytes)
}

///|
pub fn Writer::short_bytes(
  self : Writer,
  value : Bytes,
) -> Unit raise CodecError {
  self.u16(value.length())
  self.raw(value)
}

///|
pub fn Writer::bytes(self : Writer, value : Bytes?) -> Unit {
  match value {
    None => self.i32(-1)
    Some(bytes) => {
      self.i32(bytes.length())
      self.raw(bytes)
    }
  }
}

///|
pub fn Writer::to_bytes(self : Writer) -> Bytes {
  self.buffer.to_bytes()
}
