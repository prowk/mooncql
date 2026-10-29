///|
struct Place {
  street : String
  coordinate : (Int32, String?)
} derive(Eq, @debug.Debug)

///|
fn place_codec() -> @mapping.ValueCodec[Place] raise {
  let number = @mapping.int_codec()
  let text = @mapping.text_codec()
  let optional_text = text.optional()
  let coordinate : @mapping.ValueCodec[(Int32, String?)] = @mapping.ValueCodec::new(
    Tuple([Int, Varchar]),
    (value, context) => {
      TupleValue([
        context.item(0, number, value.0),
        context.item(1, optional_text, value.1),
      ])
    },
    reader => (reader.item(0).read(number), reader.item(1).read(optional_text)),
  )
  @mapping.ValueCodec::new(
    Udt("app", "place", [
      ("street", Varchar),
      ("coordinate", coordinate.cql_type()),
    ]),
    (place, context) => {
      UdtValue([
        ("street", context.field("street", text, place.street)),
        (
          "coordinate",
          context.field("coordinate", coordinate, place.coordinate),
        ),
      ])
    },
    reader => {
      street: reader.field("street").read(text),
      coordinate: reader.field("coordinate").read(coordinate),
    },
  )
}

///|
test "custom structure nested UDT and tuple have identical bytes and decoded values to direct Values" {
  let codec = place_codec()
  let place = { street: "月球大道", coordinate: (7, None), }
  let direct : @types.Value = UdtValue([
    ("street", Text("月球大道")),
    ("coordinate", TupleValue([Integer(7), Null])),
  ])
  let encoded = codec.encode(place)
  assert_eq(encoded, direct)
  assert_eq(@types.encode_value(encoded), @types.encode_value(direct))
  let decoded = @types.decode_value(
    codec.cql_type(),
    Some(@types.encode_value(direct)),
  )
  assert_eq(codec.decode(decoded), place)
  let page = @protocol.Page::new(
    [
      { keyspace: "app", table: "t", name: "id", typ: Int, },
      { keyspace: "app", table: "t", name: "home", typ: codec.cql_type(), },
    ],
    [[Integer(42), direct]],
  )
  let row_codec = @mapping.RowCodec::new(reader => {
    (
      reader.column("id").read(@mapping.int_codec()),
      reader.column("home").read(codec),
    )
  })
  assert_eq(row_codec.decode(page.row(0)), (42, place))
}

///|
test "missing columns and NULL have independent explicit policies" {
  let text = @mapping.text_codec()
  let optional = @mapping.RowCodec::new(reader => {
    reader.column("label").read(text.optional())
  })
  let required = @mapping.RowCodec::new(reader => {
    reader.column("label").read(text)
  })
  let absent = @protocol.Page::new([], [[]]).row(0)
  assert_true(
    try {
      ignore(optional.decode(absent))
      false
    } catch {
      @mapping.MappingError(path, MissingField) => path == "$[\"label\"]"
      _ => false
    },
  )
  assert_eq(optional.decode(absent, missing=MissingAsNull), None)
  assert_true(
    try {
      ignore(required.decode(absent, missing=MissingAsNull))
      false
    } catch {
      @mapping.MappingError(path, NullValue) => path == "$[\"label\"]"
      _ => false
    },
  )
  let null_row = @protocol.Page::new(
    [{ keyspace: "", table: "", name: "label", typ: Varchar, }],
    [[Null]],
  ).row(0)
  assert_eq(optional.decode(null_row), None)
  assert_true(
    try {
      ignore(required.decode(null_row))
      false
    } catch {
      @mapping.MappingError(_, NullValue) => true
      _ => false
    },
  )
  assert_eq(text.optional().encode(None), @types.Value::Null)
}

///|
test "wrong nested values and row metadata report the exact field path" {
  let codec = place_codec()
  let invalid : @types.Value = UdtValue([
    ("street", Text("ok")),
    ("coordinate", TupleValue([Text("wrong"), Null])),
  ])
  assert_true(
    try {
      ignore(codec.decode(invalid))
      false
    } catch {
      @mapping.MappingError(path, TypeMismatch) =>
        path == "$[\"coordinate\"][0]"
      _ => false
    },
  )
  let row_codec = @mapping.RowCodec::new(reader => {
    reader.column("home").read(codec)
  })
  let page = @protocol.Page::new(
    [{ keyspace: "", table: "", name: "home", typ: codec.cql_type(), }],
    [[invalid]],
  )
  assert_true(
    try {
      ignore(row_codec.decode(page.row(0)))
      false
    } catch {
      @mapping.MappingError(path, TypeMismatch) =>
        path == "$[\"home\"][\"coordinate\"][0]"
      _ => false
    },
  )
  let wrong_column = @protocol.Page::new(
    [{ keyspace: "", table: "", name: "id", typ: BigInt, }],
    [[BigInteger(42L)]],
  )
  let number = @mapping.RowCodec::new(reader => {
    reader.column("id").read(@mapping.int_codec())
  })
  assert_true(
    try {
      ignore(number.decode(wrong_column.row(0)))
      false
    } catch {
      @mapping.MappingError(path, TypeMismatch) => path == "$[\"id\"]"
      _ => false
    },
  )
}

///|
test "custom encoder cannot bypass collection NULL range unset or recursion checks" {
  let scalar : @mapping.ValueCodec[@types.Value] = @mapping.ValueCodec::new(
    TinyInt,
    (value, _) => value,
    reader => reader.value(),
  )
  assert_true(
    try {
      ignore(scalar.encode(TinyInteger(128)))
      false
    } catch {
      @mapping.MappingError(_, _) => true
    },
  )
  assert_true(
    try {
      ignore(scalar.encode(Unset))
      false
    } catch {
      @mapping.MappingError(_, InvalidValue) => true
      _ => false
    },
  )
  let list : @mapping.ValueCodec[@types.Value] = @mapping.ValueCodec::new(
    List(Int),
    (value, _) => value,
    reader => reader.value(),
  )
  assert_true(
    try {
      ignore(list.encode(ListValue([Null])))
      false
    } catch {
      @mapping.MappingError(path, InvalidValue) => path == "$[0]"
      _ => false
    },
  )
  let fields = []
  let recursive : @types.CqlType = Udt("app", "cycle", fields)
  fields.push(("again", recursive))
  assert_true(
    try {
      let _ : @mapping.ValueCodec[@types.Value] = @mapping.ValueCodec::new(
        recursive,
        (value, _) => value,
        reader => reader.value(),
      )
      false
    } catch {
      @mapping.MappingError(_, InvalidSchema) => true
      _ => false
    },
  )
  let values = []
  let recursive_value : @types.Value = ListValue(values)
  values.push(recursive_value)
  assert_true(
    try {
      ignore(list.encode(recursive_value))
      false
    } catch {
      @mapping.MappingError(_, _) => true
    },
  )
}

///|
test "schema and Value snapshots cannot be modified through codec or callback access" {
  let fields : Array[@types.CqlType] = [Int]
  let codec : @mapping.ValueCodec[@types.Value] = @mapping.ValueCodec::new(
    Tuple(fields),
    (value, _) => value,
    reader => reader.value(),
  )
  fields[0] = Varchar
  guard codec.cql_type() is Tuple(copy) else { fail("missing tuple type") }
  copy[0] = Varchar
  let items : Array[@types.Value] = [Integer(7)]
  let frozen = codec.encode(TupleValue(items))
  items[0] = Text("changed")
  assert_eq(frozen, @types.Value::TupleValue([Integer(7)]))
  guard codec.decode(frozen) is TupleValue(decoded) else {
    fail("missing tuple value")
  }
  decoded[0] = Text("changed")
  assert_eq(codec.decode(frozen), @types.Value::TupleValue([Integer(7)]))
}

///|
test "row mapping applies one shared node budget across columns before invoking application code" {
  let items : @types.Value = ListValue(Array::make(500000, Integer(1)))
  let page = @protocol.Page::new(
    [
      { keyspace: "", table: "", name: "a", typ: List(Int), },
      { keyspace: "", table: "", name: "b", typ: List(Int), },
    ],
    [[items, items]],
  )
  let invoked = [false]
  let codec = @mapping.RowCodec::new(_ => {
    invoked[0] = true
    1
  })
  assert_true(
    try {
      ignore(codec.decode(page.row(0)))
      false
    } catch {
      @mapping.MappingError(path, LimitExceeded) => path == "$[\"b\"][499998]"
      _ => false
    },
  )
  assert_true(!invoked[0])
}

///|
suberror MappingCallbackFailure {
  MappingCallbackFailure(String)
}

///|
test "nested callback errors and quoted column names preserve paths without exposing application values" {
  let broken : @mapping.ValueCodec[Int32] = @mapping.ValueCodec::new(
    Int,
    (_, _) => raise MappingCallbackFailure("private value"),
    _ => raise MappingCallbackFailure("private value"),
  )
  let parent : @mapping.ValueCodec[Int32] = @mapping.ValueCodec::new(
    Udt("app", "test", [("nested", Int)]),
    (value, context) => {
      UdtValue([("nested", context.field("nested", broken, value))])
    },
    reader => reader.field("nested").read(broken),
  )
  assert_true(
    try {
      ignore(parent.encode(7))
      false
    } catch {
      @mapping.MappingError(path, CallbackFailed) => path == "$[\"nested\"]"
      _ => false
    },
  )
  assert_true(
    try {
      ignore(parent.decode(UdtValue([("nested", Integer(7))])))
      false
    } catch {
      @mapping.MappingError(path, CallbackFailed) => path == "$[\"nested\"]"
      _ => false
    },
  )
  let decoder = @mapping.RowCodec::new(reader => {
    reader.column("a\"b.c").read(@mapping.int_codec())
  })
  let page = @protocol.Page::new(
    [{ keyspace: "", table: "", name: "a\"b.c", typ: Varchar, }],
    [[Text("private value")]],
  )
  assert_true(
    try {
      ignore(decoder.decode(page.row(0)))
      false
    } catch {
      @mapping.MappingError(path, TypeMismatch) => path == "$[\"a\\\"b.c\"]"
      _ => false
    },
  )
}
