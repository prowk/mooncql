///|
test "decode rows global metadata null and paging state" {
  let w = @codec.Writer::new()
  w.i32(2)
  w.i32(3)
  w.i32(2)
  w.bytes(Some(b"opaque"))
  w.string("ks")
  w.string("events")
  w.string("id")
  w.u16(2)
  w.string("message")
  w.u16(13)
  w.i32(2)
  @types.write_value(w, BigInteger(9007199254740993L))
  @types.write_value(w, Text("中文"))
  @types.write_value(w, BigInteger(2L))
  @types.write_value(w, Null)
  guard @protocol.decode_result(w.to_bytes()) is Rows(page) else {
    fail("expected rows")
  }
  assert_eq(page.rows.length(), 2)
  assert_eq(page.get(0, "id"), @types.Value::BigInteger(9007199254740993L))
  assert_eq(page.get(0, "message"), @types.Value::Text("中文"))
  assert_eq(page.get(1, "message"), @types.Value::Null)
  assert_eq(page.paging_state, Some(b"opaque"))
}

///|
test "server errors preserve structured timeout and unprepared details" {
  let w = @codec.Writer::new()
  w.i32(0x1200)
  w.string("read timed out")
  w.u16(4)
  w.i32(1)
  w.i32(2)
  w.u8(0)
  let error = @protocol.decode_error(w.to_bytes())
  assert_eq(error.code, 0x1200)
  assert_true(error.detail is ReadTimeout(4, 1, 2, false))
  let w = @codec.Writer::new()
  w.i32(0x2500)
  w.string("unknown statement")
  w.short_bytes(b"id")
  assert_true(@protocol.decode_error(w.to_bytes()).detail is Unprepared(b"id"))
}

///|
test "missing metadata and impossible row counts fail explicitly" {
  let w = @codec.Writer::new()
  w.i32(2)
  w.i32(4)
  w.i32(1)
  w.i32(0)
  assert_true(
    try {
      ignore(@protocol.decode_result(w.to_bytes()))
      false
    } catch {
      _ => true
    },
  )
  let w = @codec.Writer::new()
  w.i32(2)
  w.i32(0)
  w.i32(0)
  w.i32(1000000)
  assert_true(
    try {
      ignore(@protocol.decode_result(w.to_bytes()))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "nested type metadata is parsed and recursion bounded" {
  let w = @codec.Writer::new()
  w.u16(33)
  w.u16(13)
  w.u16(32)
  w.u16(9)
  assert_eq(
    @types.read_type(@codec.Reader::new(w.to_bytes())),
    @types.CqlType::Map(Varchar, List(Int)),
  )
  let w = @codec.Writer::new()
  for i = 0; i < 33; i = i + 1 {
    w.u16(32)
  }
  w.u16(9)
  assert_true(
    try {
      ignore(@types.read_type(@codec.Reader::new(w.to_bytes())))
      false
    } catch {
      _ => true
    },
  )
}
