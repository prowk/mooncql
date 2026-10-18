///|
test "Row distinguishes missing null and mismatched columns without losing raw values" {
  let columns : Array[@protocol.Column] = [
    { keyspace: "ks", table: "t", name: "id", typ: BigInt, },
    { keyspace: "ks", table: "t", name: "text", typ: Varchar, },
    { keyspace: "ks", table: "t", name: "optional", typ: Int, },
  ]
  let page = @protocol.Page::new(columns, [
    [BigInteger(9007199254740993L), Text("中文"), Null],
  ])
  let row = page.row(0)
  assert_eq(row.int64("id"), 9007199254740993L)
  assert_eq(row.text("text"), "中文")
  assert_true(row.is_null("optional"))
  assert_eq(row.value("optional"), @types.Value::Null)
  assert_eq(row.value_at(0), @types.Value::BigInteger(9007199254740993L))
  assert_true(
    try {
      ignore(row.text("missing"))
      false
    } catch {
      @protocol.MissingColumn("missing", "text") => true
      _ => false
    },
  )
  assert_true(
    try {
      ignore(row.int("optional"))
      false
    } catch {
      @protocol.NullColumn("optional", "int") => true
      _ => false
    },
  )
  assert_true(
    try {
      ignore(row.int("id"))
      false
    } catch {
      @protocol.TypeMismatch("id", "int", "bigint") => true
      _ => false
    },
  )
  assert_true(
    try {
      ignore(page.row(-1))
      false
    } catch {
      @protocol.InvalidRow(_) => true
      _ => false
    },
  )
  assert_true(
    try {
      ignore(row.value_at(3))
      false
    } catch {
      @protocol.InvalidRow(_) => true
      _ => false
    },
  )
  page.rows[0].clear()
  assert_true(
    try {
      ignore(row.text("text"))
      false
    } catch {
      @protocol.InvalidRow(_) => true
      _ => false
    },
  )
  assert_true(
    try {
      ignore(page.get(0, "id"))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "Page freezes nested metadata and preserves the first duplicate name" {
  let fields : Array[@types.CqlType] = [Int]
  let columns : Array[@protocol.Column] = [
    { keyspace: "ks", table: "t", name: "tuple", typ: Tuple(fields), },
    { keyspace: "ks", table: "t", name: "same", typ: Int, },
    { keyspace: "ks", table: "t", name: "same", typ: Int, },
  ]
  let page = @protocol.Page::new(columns, [
    [TupleValue([Integer(7)]), Integer(1), Integer(2)],
  ])
  fields[0] = Varchar
  columns[1] = { ..columns[1], name: "changed", }
  page.columns.clear()
  let row = page.row(0)
  assert_eq(row.int("same"), 1)
  assert_eq(page.get(0, "same"), @types.Value::Integer(1))
  let snapshot = row.columns_snapshot()
  guard snapshot[0].typ is Tuple(items) else { fail("expected tuple") }
  assert_eq(items[0], @types.CqlType::Int)
  items[0] = Blob
  guard page.columns_snapshot()[0].typ is Tuple(items) else {
    fail("expected tuple")
  }
  assert_eq(items[0], @types.CqlType::Int)
  assert_eq(row.tuple("tuple"), [@types.Value::Integer(7)])
  assert_true(
    try {
      ignore(@protocol.Page::new(columns, [[]]))
      false
    } catch {
      _ => true
    },
  )
  let mut typ : @types.CqlType = Int
  for _ in 0..<33 {
    typ = List(typ)
  }
  assert_true(
    try {
      ignore(
        @protocol.Page::new([{ keyspace: "", table: "", name: "deep", typ, }], []),
      )
      false
    } catch {
      _ => true
    },
  )
}

///|
test "Row exact getters preserve UUID temporal decimal and varint payloads" {
  let values : Array[(@types.CqlType, @types.Value)] = [
    (Uuid, Uuid(b"0123456789abcdef")),
    (Date, Date(-2147483648)),
    (Time, Time(86399999999999L)),
    (Timestamp, Timestamp(-9223372036854775808L)),
    (Decimal, Decimal(-2147483648, b"\xff\x00")),
    (VarInt, VarInt(b"\x00\x80")),
    (TinyInt, TinyInteger(-128)),
    (SmallInt, SmallInteger(32767)),
    (Boolean, Boolean(true)),
    (Double, Real(1.25)),
    (Float, Single(1.5F)),
    (Blob, Bytes(b"\x00\xff")),
    (Inet, Inet(b"\x7f\x00\x00\x01")),
    (Duration, Duration(1, 2, 3L)),
    (List(Int), ListValue([Integer(1)])),
    (Set(Int), SetValue([Integer(2)])),
    (Map(Int, Varchar), MapValue([(Integer(3), Text("x"))])),
    (Udt("ks", "u", [("x", Int)]), UdtValue([("x", Integer(4))])),
  ]
  let columns : Array[@protocol.Column] = values.map(pair => {
    keyspace: "ks",
    table: "t",
    name: pair.0.to_repr().to_string(),
    typ: pair.0,
  })
  let row = @protocol.Page::new(columns, [values.map(pair => pair.1)]).row(0)
  assert_eq(row.uuid(columns[0].name).to_bytes(), b"0123456789abcdef")
  assert_eq(row.date(columns[1].name).days(), -2147483648)
  assert_eq(row.time(columns[2].name).nanos(), 86399999999999L)
  assert_eq(row.timestamp(columns[3].name).millis(), -9223372036854775808L)
  assert_eq(
    row.decimal(columns[4].name).to_scientific_string(),
    "-256e2147483648",
  )
  assert_eq(row.varint(columns[5].name).to_decimal_string(), "128")
  assert_eq(row.int(columns[6].name), -128)
  assert_eq(row.int64(columns[7].name), 32767L)
  assert_true(row.boolean(columns[8].name))
  assert_eq(row.double(columns[9].name), 1.25)
  assert_eq(row.float(columns[10].name), 1.5F)
  assert_eq(row.bytes(columns[11].name), b"\x00\xff")
  assert_eq(row.inet(columns[12].name), b"\x7f\x00\x00\x01")
  assert_eq(row.duration(columns[13].name), (1, 2, 3L))
  assert_eq(row.list(columns[14].name), [@types.Value::Integer(1)])
  assert_eq(row.set(columns[15].name), [@types.Value::Integer(2)])
  assert_eq(row.map(columns[16].name), [
    (@types.Value::Integer(3), @types.Value::Text("x")),
  ])
  assert_eq(row.udt(columns[17].name), [("x", @types.Value::Integer(4))])
}
