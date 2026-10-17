///|
test "nested collections tuples and UDT preserve typed values" {
  let cases : Array[(@types.CqlType, @types.Value)] = [
    (List(Int), ListValue([Integer(1), Integer(-2)])),
    (Set(Varchar), SetValue([Text("中文"), Text("event")])),
    (
      Map(Varchar, List(BigInt)),
      MapValue([(Text("key"), ListValue([BigInteger(9007199254740993L)]))]),
    ),
    (Tuple([Varchar, Int]), TupleValue([Text("tuple"), Null])),
    (
      Udt("ks", "event", [("name", Varchar), ("id", Int)]),
      UdtValue([("name", Text("事件")), ("id", Integer(42))]),
    ),
  ]
  for (typ, value) in cases {
    @types.validate(typ, value)
    assert_eq(@types.decode_value(typ, Some(@types.encode_value(value))), value)
  }
}

///|
test "collections reject null members incompatible types and malicious counts" {
  assert_true(
    try {
      @types.validate(List(Int), ListValue([Text("bad")]))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(@types.encode_value(ListValue([Null])))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(@types.decode_value(List(Int), Some(b"\x7f\xff\xff\xff")))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(
        @types.decode_value(
          Map(Int, Int),
          Some(b"\x00\x00\x00\x01\xff\xff\xff\xff\xff\xff\xff\xff"),
        ),
      )
      false
    } catch {
      _ => true
    },
  )
}

///|
test "binding snapshots are deep and recursive inputs are bounded" {
  let elements : Array[@types.Value] = [Integer(1)]
  let copied = @types.snapshot([ListValue(elements)])
  elements[0] = Integer(2)
  assert_eq(copied, [@types.Value::ListValue([Integer(1)])])
  let mut value : @types.Value = Integer(1)
  for i = 0; i < 33; i = i + 1 {
    value = ListValue([value])
  }
  assert_true(
    try {
      ignore(@types.encode_value(value))
      false
    } catch {
      _ => true
    },
  )
}
