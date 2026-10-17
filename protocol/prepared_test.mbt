///|
test "prepared metadata includes partition indices and result columns" {
  let w = @codec.Writer::new()
  w.i32(4)
  w.short_bytes(b"statement-id")
  w.i32(1)
  w.i32(2)
  w.i32(1)
  w.u16(0)
  w.string("ks")
  w.string("events")
  w.string("device")
  w.u16(9)
  w.string("message")
  w.u16(13)
  w.i32(1)
  w.i32(1)
  w.string("ks")
  w.string("events")
  w.string("device")
  w.u16(9)
  guard @protocol.decode_result(w.to_bytes()) is Prepared(statement) else {
    fail("expected prepared")
  }
  assert_eq(statement.id, b"statement-id")
  assert_eq(statement.parameters.length(), 2)
  assert_eq(statement.partition_key_indices, [0])
  assert_eq(statement.result_columns[0].name, "device")
}

///|
test "execute includes opaque id and paging continuation" {
  let request = @protocol.execute(
    b"id",
    [Integer(7)],
    options=@protocol.QueryOptions::new(page_size=3, paging_state=b"next"),
  )
  assert_eq(request.opcode, 10)
  let r = @codec.Reader::new(request.body)
  assert_eq(r.short_bytes(), b"id")
  assert_eq(r.u16(), 10)
  assert_eq(r.u8(), 13)
  assert_eq(r.u16(), 1)
  assert_eq(r.bytes(), Some(b"\x00\x00\x00\x07"))
  assert_eq(r.i32(), 3)
  assert_eq(r.bytes(), Some(b"next"))
  r.finish()
}

///|
test "No_metadata requires matching cached columns" {
  let w = @codec.Writer::new()
  w.i32(2)
  w.i32(4)
  w.i32(1)
  w.i32(1)
  @types.write_value(w, Integer(42))
  let columns : Array[@protocol.Column] = [
    { keyspace: "ks", table: "t", name: "id", typ: Int, },
  ]
  guard @protocol.decode_result(w.to_bytes(), cached=columns) is Rows(page) else {
    fail("expected rows")
  }
  assert_eq(page.get(0, "id"), @types.Value::Integer(42))
}
