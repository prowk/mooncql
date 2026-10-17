///|
test "v5 query uses int flags keyspace now and named values in wire order" {
  let request = @protocol.query(
    "SELECT :v",
    values=[Integer(3)],
    options=@protocol.QueryOptions::new(
      keyspace="应用",
      now_in_seconds=123,
      value_names=["v"],
      skip_metadata=true,
    ),
  )
  let r = @codec.Reader::new(request.body)
  assert_eq(r.long_string(), "SELECT :v")
  assert_eq(r.u16(), 10)
  assert_eq(r.i32(), 0x1c3)
  assert_eq(r.u16(), 1)
  assert_eq(r.string(), "v")
  assert_eq(r.bytes(), Some(b"\x00\x00\x00\x03"))
  assert_eq(r.string(), "应用")
  assert_eq(r.i32(), 123)
  r.finish()
  let r = @codec.Reader::new(
    @protocol.prepare("SELECT * FROM t", keyspace="ks").body,
  )
  assert_eq(r.long_string(), "SELECT * FROM t")
  assert_eq(r.i32(), 1)
  assert_eq(r.string(), "ks")
  r.finish()
}

///|
test "v5 batch encodes simple and prepared statements and int options" {
  let request = @protocol.batch(
    [Query("INSERT ?", [Integer(7)]), Prepared(b"id", [Null, Unset])],
    kind=Unlogged,
    options=@protocol.QueryOptions::new(
      serial_consistency=LocalSerial,
      timestamp=123L,
      keyspace="ks",
      now_in_seconds=456,
    ),
  )
  assert_eq(request.opcode, 13)
  let r = @codec.Reader::new(request.body)
  assert_eq(r.u8(), 1)
  assert_eq(r.u16(), 2)
  assert_eq(r.u8(), 0)
  assert_eq(r.long_string(), "INSERT ?")
  assert_eq(r.u16(), 1)
  assert_eq(r.bytes(), Some(b"\x00\x00\x00\x07"))
  assert_eq(r.u8(), 1)
  assert_eq(r.short_bytes(), b"id")
  assert_eq(r.u16(), 2)
  assert_eq(r.i32(), -1)
  assert_eq(r.i32(), -2)
  assert_eq(r.u16(), 10)
  assert_eq(r.i32(), 0x1b0)
  assert_eq(r.u16(), 9)
  assert_eq(r.i64(), 123L)
  assert_eq(r.string(), "ks")
  assert_eq(r.i32(), 456)
  r.finish()
  assert_true(
    try {
      ignore(
        @protocol.batch(
          [Query("x", [])],
          options=@protocol.QueryOptions::new(page_size=1),
        ),
      )
      false
    } catch {
      _ => true
    },
  )
}

///|
test "v5 metadata changed precedes column specs and cannot omit metadata" {
  let w = @codec.Writer::new()
  w.i32(2)
  w.i32(11)
  w.i32(1)
  w.bytes(Some(b"next"))
  w.short_bytes(b"new-id")
  w.string("ks")
  w.string("t")
  w.string("value")
  w.u16(9)
  w.i32(1)
  @types.write_value(w, Integer(42))
  guard @protocol.decode_result(w.to_bytes()) is Rows(page) else {
    fail("expected rows")
  }
  assert_eq(page.new_metadata_id, Some(b"new-id"))
  assert_eq(page.paging_state, Some(b"next"))
  assert_eq(page.get(0, "value"), @types.Value::Integer(42))
  assert_true(
    try {
      ignore(
        @protocol.read_metadata(
          @codec.Reader::new(b"\x00\x00\x00\x0c\x00\x00\x00\x00"),
        ),
      )
      false
    } catch {
      _ => true
    },
  )
}

///|
test "v5 failure reasons IPv4 IPv6 and CAS contentions" {
  for read in [true, false] {
    let w = @codec.Writer::new()
    w.i32(if read { 0x1300 } else { 0x1500 })
    w.string("failed")
    w.u16(4)
    w.i32(1)
    w.i32(2)
    w.i32(2)
    w.u8(4)
    w.raw(b"\x7f\x00\x00\x01")
    w.u16(3)
    w.u8(16)
    w.raw(b"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01")
    w.u16(7)
    if read {
      w.u8(1)
    } else {
      w.string("BATCH")
    }
    let reasons = match @protocol.decode_error(w.to_bytes()).detail {
      ReadFailure(4, 1, 2, reasons, true) => reasons
      WriteFailure(4, 1, 2, reasons, "BATCH") => reasons
      _ => fail("wrong failure detail")
    }
    assert_eq(reasons.length(), 2)
    assert_eq(reasons[0].endpoint, b"\x7f\x00\x00\x01")
    assert_eq(reasons[1].endpoint.length(), 16)
    assert_eq(reasons[1].code, 7)
  }
  let w = @codec.Writer::new()
  w.i32(0x1100)
  w.string("timeout")
  w.u16(4)
  w.i32(1)
  w.i32(2)
  w.string("CAS")
  w.u16(12)
  assert_true(
    @protocol.decode_error(w.to_bytes()).detail
    is WriteTimeout(4, 1, 2, "CAS", Some(12)),
  )
}
