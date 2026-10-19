///|
test "ROWS shares one value budget across cells including omitted UDT fields" {
  let columns : Array[@protocol.Column] = [
    {
      keyspace: "ks",
      table: "events",
      name: "value",
      typ: Udt("ks", "wide", Array::makei(64, i => ("f\{i}", Int))),
    },
  ]
  let writer = @codec.Writer::new()
  writer.i32(2)
  writer.i32(4)
  writer.i32(1)
  writer.i32(2)
  writer.bytes(Some(b""))
  writer.bytes(Some(b""))
  let body = writer.to_bytes()
  guard @protocol.decode_result(body, cached=columns, max_value_nodes=130)
    is Rows(page) else {
    fail("expected rows")
  }
  assert_eq(page.rows.length(), 2)
  for row in page.rows {
    guard row[0] is UdtValue(fields) else { fail("expected UDT") }
    assert_eq(fields.length(), 64)
    for pair in fields {
      assert_eq(pair.1, @types.Value::Null)
    }
  }
  assert_true(
    try {
      ignore(@protocol.decode_result(body, cached=columns, max_value_nodes=129))
      false
    } catch {
      @codec.CodecError(_) => true
    },
  )
  assert_true(@protocol.decode_result(body, cached=columns) is Rows(_))
}

///|
test "NULL cells consume one node without expanding UDT metadata and empty pages avoid division by zero" {
  let columns : Array[@protocol.Column] = [
    {
      keyspace: "ks",
      table: "events",
      name: "value",
      typ: Udt("ks", "wide", Array::makei(64, i => ("f\{i}", Int))),
    },
  ]
  let writer = @codec.Writer::new()
  writer.i32(2)
  writer.i32(4)
  writer.i32(1)
  writer.i32(2)
  writer.bytes(None)
  writer.bytes(None)
  let body = writer.to_bytes()
  guard @protocol.decode_result(body, cached=columns, max_value_nodes=2)
    is Rows(page) else {
    fail("expected rows")
  }
  assert_eq(page.rows, [[@types.Value::Null], [@types.Value::Null]])
  assert_true(
    try {
      ignore(@protocol.decode_result(body, cached=columns, max_value_nodes=1))
      false
    } catch {
      @codec.CodecError(_) => true
    },
  )
  let writer = @codec.Writer::new()
  writer.i32(2)
  writer.i32(0)
  writer.i32(0)
  writer.i32(0)
  guard @protocol.decode_result(writer.to_bytes(), max_value_nodes=1)
    is Rows(empty_page) else {
    fail("expected empty page")
  }
  assert_eq(empty_page.rows.length(), 0)
}
