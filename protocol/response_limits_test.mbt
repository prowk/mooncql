///|
test "cached metadata cannot bypass nesting limit even for NULL cells or empty pages" {
  let columns : Array[@protocol.Column] = [
    { keyspace: "ks", table: "t", name: "deep", typ: List(List(Int)), },
  ]
  for rows in [0, 1] {
    let w = @codec.Writer::new()
    w.i32(2)
    w.i32(4)
    w.i32(1)
    w.i32(rows)
    if rows == 1 {
      w.bytes(None)
    }
    let body = w.to_bytes()
    assert_true(
      @protocol.decode_result_limited(body, cached=columns, max_depth=3)
      is Rows(_),
    )
    assert_true(
      try {
        ignore(
          @protocol.decode_result_limited(body, cached=columns, max_depth=2),
        )
        false
      } catch {
        @codec.CodecError(_) => true
      },
    )
  }
}

///|
test "invalid decode limits fail for VOID as well as ROWS" {
  for
    (nodes, rows, columns, depth) in [
      (0, 1, 1, 1),
      (1000001, 1, 1, 1),
      (1, -1, 1, 1),
      (1, 1000001, 1, 1),
      (1, 1, -1, 1),
      (1, 1, 65536, 1),
      (1, 1, 1, 0),
      (1, 1, 1, 33),
    ] {
    assert_true(
      try {
        ignore(
          @protocol.decode_result_limited(
            b"\x00\x00\x00\x01",
            max_value_nodes=nodes,
            max_rows=rows,
            max_columns=columns,
            max_depth=depth,
          ),
        )
        false
      } catch {
        @codec.CodecError(_) => true
      },
    )
  }
}
