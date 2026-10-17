///|
test "startup declares CQL language version and not binary protocol version" {
  let request = @protocol.startup()
  assert_eq(request.opcode, 1)
  let r = @codec.Reader::new(request.body)
  assert_eq(r.u16(), 1)
  assert_eq(r.string(), "CQL_VERSION")
  assert_eq(r.string(), "3.0.0")
  r.finish()
}

///|
test "password authenticator PLAIN token is length prefixed" {
  let request = @protocol.password_auth("用户", "secret")
  let r = @codec.Reader::new(request.body)
  assert_eq(r.bytes(), Some(b"\x00\xe7\x94\xa8\xe6\x88\xb7\x00secret"))
  r.finish()
  assert_true(
    try {
      ignore(@protocol.password_auth("a\u0000b", "x"))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "query parameters have ordered flags and bound values" {
  let request = @protocol.query(
    "SELECT ?",
    values=[Integer(42), Null, Unset],
    options=@protocol.QueryOptions::new(
      consistency=Quorum,
      page_size=7,
      paging_state=b"cursor",
      serial_consistency=LocalSerial,
      timestamp=123L,
    ),
  )
  let r = @codec.Reader::new(request.body)
  assert_eq(r.long_string(), "SELECT ?")
  assert_eq(r.u16(), 4)
  assert_eq(r.u8(), 61)
  assert_eq(r.u16(), 3)
  assert_eq(r.bytes(), Some(b"\x00\x00\x00\x2a"))
  assert_eq(r.i32(), -1)
  assert_eq(r.i32(), -2)
  assert_eq(r.i32(), 7)
  assert_eq(r.bytes(), Some(b"cursor"))
  assert_eq(r.u16(), 9)
  assert_eq(r.i64(), 123L)
  r.finish()
}

///|
test "reject invalid page size and serial consistency before sending" {
  assert_true(
    try {
      ignore(
        @protocol.query("x", options=@protocol.QueryOptions::new(page_size=0)),
      )
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(
        @protocol.query(
          "x",
          options=@protocol.QueryOptions::new(serial_consistency=One),
        ),
      )
      false
    } catch {
      _ => true
    },
  )
}
