///|
test "snapshot copy cost preserves nested isolation with a bounded representative corpus" {
  let leaf : Array[@types.Value] = Array::makei(1024, index => Integer(index))
  let values : Array[@types.Value] = [
    UdtValue([("items", ListValue([TupleValue(leaf)]))]),
  ]
  let start = @async.now()
  for _ in 0..<1000 {
    let copy = @types.snapshot(values)
    guard copy[0] is UdtValue(fields) &&
      fields[0].1 is ListValue(items) &&
      items[0] is TupleValue(copied) else {
      fail("missing nested copy")
    }
    copied[0] = Text("copy only")
    assert_eq(leaf[0], @types.Value::Integer(0))
  }
  println(
    "snapshot-cost copies=1000 value_nodes_per_copy=1027 elapsed_ms=\{@async.now() - start}; immutable bytes and strings shared, nested arrays isolated",
  )
}
