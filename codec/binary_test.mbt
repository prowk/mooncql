///|
test "network byte order and signed boundaries" {
  let w = @codec.Writer::new()
  w.u16(65535)
  w.i32(-2147483648)
  w.i64(-9223372036854775807L - 1)
  w.i64(9007199254740993L)
  assert_eq(w.to_bytes()[0:6].to_owned(), b"\xff\xff\x80\x00\x00\x00")
  let r = @codec.Reader::new(w.to_bytes())
  assert_eq(r.u16(), 65535)
  assert_eq(r.i32(), -2147483648)
  assert_eq(r.i64(), -9223372036854775807L - 1)
  assert_eq(r.i64(), 9007199254740993L)
  r.finish()
}

///|
test "UTF-8 length is bytes and nullable bytes remain distinct" {
  let w = @codec.Writer::new()
  w.string("中文")
  w.bytes(None)
  w.bytes(Some(b""))
  let r = @codec.Reader::new(w.to_bytes())
  assert_eq(r.string(), "中文")
  assert_eq(r.bytes(), None)
  assert_eq(r.bytes(), Some(b""))
  r.finish()
}

///|
test "reject malformed lengths UTF-8 and trailing data" {
  let r = @codec.Reader::new(b"\x00\x02x")
  assert_true((r.string() catch { @codec.CodecError(_) => "error" }) == "error")
  let r = @codec.Reader::new(b"\x00\x01\xff")
  assert_true((r.string() catch { @codec.CodecError(_) => "error" }) == "error")
  let r = @codec.Reader::new(b"\xff\xff\xff\xfe")
  assert_true(
    try {
      ignore(r.bytes())
      false
    } catch {
      @codec.CodecError(_) => true
    },
  )
  let r = @codec.Reader::new(b"x")
  assert_true(
    try {
      r.finish()
      false
    } catch {
      @codec.CodecError(_) => true
    },
  )
}
