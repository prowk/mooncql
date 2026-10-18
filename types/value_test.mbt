///|
test "scalar round trips preserve types and precision" {
  let cases : Array[(@types.CqlType, @types.Value)] = [
    (Varchar, Text("中文事件")),
    (BigInt, BigInteger(9007199254740993L)),
    (Int, Integer(-2147483648)),
    (Boolean, Boolean(true)),
    (Blob, Bytes(b"\x00\xff")),
    (Double, Real(-1.25)),
    (Float, Single(1.5F)),
    (Timestamp, Timestamp(1700000000000L)),
    (Date, Date(-100)),
    (Time, Time(86399999999999L)),
    (SmallInt, SmallInteger(-32768)),
    (TinyInt, TinyInteger(-128)),
    (Uuid, Uuid(b"0123456789abcdef")),
    (Inet, Inet(b"\x7f\x00\x00\x01")),
    (Decimal, Decimal(3, b"\x00\x80")),
    (VarInt, VarInt(b"\xff\x00")),
  ]
  for (typ, value) in cases {
    assert_eq(
      @types.decode_value(typ, Some(@types.encode_scalar(value))),
      value,
    )
  }
}

///|
test "null unset and empty payload are distinct wire values" {
  let w = @codec.Writer::new()
  @types.write_value(w, Null)
  @types.write_value(w, Unset)
  @types.write_value(w, Text(""))
  assert_eq(w.to_bytes(), b"\xff\xff\xff\xff\xff\xff\xff\xfe\x00\x00\x00\x00")
  assert_eq(@types.decode_value(Varchar, None), @types.Value::Null)
}

///|
test "reject malformed scalar payloads and range overflow" {
  for
    (typ, bytes) in [
      (@types.CqlType::Int, b"\x01"),
      (Boolean, b"\x02\x00"),
      (Uuid, b"short"),
      (Int, b"\x00\x00\x00\x01x"),
    ] {
    assert_true(
      try {
        ignore(@types.decode_value(typ, Some(bytes)))
        false
      } catch {
        _ => true
      },
    )
  }
  assert_true(
    try {
      ignore(@types.encode_scalar(TinyInteger(128)))
      false
    } catch {
      _ => true
    },
  )
}
