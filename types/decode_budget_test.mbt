///|
test "shared decode budget counts omitted UDT fields and rejects expansion before allocation" {
  let typ : @types.CqlType = Udt(
    "ks",
    "wide",
    Array::makei(64, i => ("f\{i}", Int)),
  )
  let budget = @types.DecodeBudget::new(max_nodes=130)
  for _ in 0..<2 {
    guard @types.decode_value(typ, Some(b""), budget~) is UdtValue(fields) else {
      fail("expected UDT")
    }
    assert_eq(fields.length(), 64)
    for pair in fields {
      assert_eq(pair.1, @types.Value::Null)
    }
  }
  assert_eq(budget.remaining_nodes(), 0)
  assert_true(
    try {
      ignore(@types.decode_value(typ, Some(b""), budget~))
      false
    } catch {
      @codec.CodecError(_) => true
    },
  )
  let budget = @types.DecodeBudget::new(max_nodes=64)
  assert_true(
    try {
      ignore(@types.decode_value(typ, Some(b""), budget~))
      false
    } catch {
      @codec.CodecError(_) => true
    },
  )
  // 根节点已计数，字段数组在预算预检失败后不再展开。
  assert_eq(budget.remaining_nodes(), 63)
}

///|
test "nested containers null and empty values all consume the same node budget" {
  let typ : @types.CqlType = Map(Varchar, List(Tuple([Int, Varchar])))
  let value : @types.Value = MapValue([
    (Text("key"), ListValue([TupleValue([Integer(7), Null])])),
  ])
  let bytes = @types.encode_value(value)
  // map、key、list、tuple、整数、NULL 共六个节点。
  let budget = @types.DecodeBudget::new(max_nodes=6)
  assert_eq(@types.decode_value(typ, Some(bytes), budget~), value)
  assert_eq(budget.remaining_nodes(), 0)
  assert_true(
    try {
      ignore(
        @types.decode_value(
          typ,
          Some(bytes),
          budget=@types.DecodeBudget::new(max_nodes=5),
        ),
      )
      false
    } catch {
      @codec.CodecError(_) => true
    },
  )
  let budget = @types.DecodeBudget::new(max_nodes=2)
  assert_eq(@types.decode_value(Int, Some(b""), budget~), @types.Value::Empty)
  assert_eq(@types.decode_value(typ, None, budget~), @types.Value::Null)
  assert_eq(budget.remaining_nodes(), 0)
}

///|
test "decode budget validates limits and defaults to one million nodes" {
  assert_eq(@types.DecodeBudget::new().remaining_nodes(), 1000000)
  for max_nodes in [0, -1, 1000001] {
    assert_true(
      try {
        ignore(@types.DecodeBudget::new(max_nodes~))
        false
      } catch {
        @codec.CodecError(_) => true
      },
    )
  }
}
