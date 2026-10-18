///|
test "noncanonical true bytes follow v5 and scalar empty is distinct from NULL" {
  for value in [1, 2, 127, 128, 255] {
    assert_eq(
      @types.decode_value(Boolean, Some(Bytes::from_array([value.to_byte()]))),
      @types.Value::Boolean(true),
    )
  }
  for
    typ in [
      @types.CqlType::Int,
      BigInt,
      Counter,
      Boolean,
      Float,
      Double,
      Uuid,
      TimeUuid,
      Inet,
      Timestamp,
      Date,
      Time,
      Decimal,
      VarInt,
      Duration,
      SmallInt,
      TinyInt,
    ] {
    assert_eq(@types.decode_value(typ, Some(b"")), @types.Value::Empty)
    assert_eq(@types.decode_value(typ, None), @types.Value::Null)
    @types.validate(typ, Empty)
    assert_eq(@types.encode_value(Empty), b"")
  }
  let writer = @codec.Writer::new()
  @types.write_value(writer, Empty)
  @types.write_value(writer, Null)
  assert_eq(writer.to_bytes(), b"\x00\x00\x00\x00\xff\xff\xff\xff")
  assert_eq(@types.decode_value(Varchar, Some(b"")), @types.Value::Text(""))
  assert_eq(@types.decode_value(Blob, Some(b"")), @types.Value::Bytes(b""))
}

///|
test "short UDT and tuple append absent trailing fields as NULL but reject partial lengths" {
  let payload = b"\x00\x00\x00\x04\x00\x00\x00\x07"
  let typ : @types.CqlType = Udt("ks", "point", [("x", Int), ("label", Varchar)])
  assert_eq(
    @types.decode_value(typ, Some(payload)),
    @types.Value::UdtValue([("x", Integer(7)), ("label", Null)]),
  )
  assert_eq(
    @types.decode_value(typ, Some(b"")),
    @types.Value::UdtValue([("x", Null), ("label", Null)]),
  )
  assert_eq(
    @types.decode_value(Tuple([Int, Varchar]), Some(payload)),
    @types.Value::TupleValue([Integer(7), Null]),
  )
  assert_true(
    try {
      ignore(@types.decode_value(typ, Some(payload + b"\x00")))
      false
    } catch {
      _ => true
    },
  )
}
