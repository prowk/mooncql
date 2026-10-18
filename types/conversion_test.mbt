///|
test "conversion rejects invalid dates precision loss and overflow" {
  for
    text in [
      "2023-02-29", "1900-02-29", "2000-04-31", "2020-00-01", "2020-01-00", "00000-01-01",
      "+10000-01-01", "-999999999999-01-01", "1970-01-01x",
    ] {
    assert_true(
      try {
        ignore(@types.CqlDate::from_string(text))
        false
      } catch {
        _ => true
      },
    )
  }
  assert_eq(@types.CqlDate::from_string("2000-02-29").to_string(), "2000-02-29")
  for
    text in [
      "24:00:00", "12:60:00", "23:59:60", "00:00:00.", "00:00:00.0000000001", "0:00:00",
    ] {
    assert_true(
      try {
        ignore(@types.CqlTime::from_string(text))
        false
      } catch {
        _ => true
      },
    )
  }
  for
    text in [
      "1970-01-01T00:00:00.000000001Z", "1970-01-01T00:00:00", "1970-01-01T00:00:00+24:00",
      "1970-01-01T00:00:00+00:60", "1970-01-01T中文中文中文Z", "-292275055-05-16T16:47:04.191Z",
      "+292278994-08-17T07:12:55.808Z",
    ] {
    assert_true(
      try {
        ignore(@types.CqlTimestamp::from_string(text))
        false
      } catch {
        _ => true
      },
    )
  }
  assert_eq(
    @types.CqlTimestamp::from_string("1970-01-01T01:30:00+01:30").millis(),
    0L,
  )
  assert_eq(
    @types.CqlTimestamp::from_string("1969-12-31T23:59:59.999000000Z").millis(),
    -1L,
  )
  assert_eq(
    @types.CqlTimestamp::from_string("1970-01-01T23:00:00-01:00").millis(),
    86400000L,
  )
  for text in ["", "+", "-", "1.0", "１２", "1e3"] {
    assert_true(
      try {
        ignore(@types.CqlVarInt::from_decimal_string(text))
        false
      } catch {
        _ => true
      },
    )
  }
  assert_eq(
    @types.CqlVarInt::from_bytes(b"\xff\xff\x80").to_decimal_string(),
    "-128",
  )
  assert_eq(
    @types.CqlVarInt::from_bytes(b"\x00\x00\x80").to_decimal_string(),
    "128",
  )
  assert_eq(
    @types.CqlVarInt::from_decimal_string("-000").to_decimal_string(),
    "0",
  )
  assert_true(
    try {
      ignore(@types.CqlVarInt::from_decimal_string("100", max_digits=2))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(
        @types.CqlVarInt::from_bytes(b"\x00\x80").to_decimal_string(
          max_digits=2,
        ),
      )
      false
    } catch {
      _ => true
    },
  )
  for
    text in [".", ".e1", "1e", "1e+", "1.2.3", "1e2147483649", "1e-2147483648"] {
    assert_true(
      try {
        ignore(@types.CqlDecimal::from_string(text))
        false
      } catch {
        _ => true
      },
    )
  }
  for scale in [-2147483648, 2147483647] {
    let value = @types.CqlDecimal::from_parts(scale, b"\x01")
    assert_eq(
      @types.CqlDecimal::from_string(value.to_scientific_string()).to_value(),
      value.to_value(),
    )
    assert_true(
      try {
        ignore(value.to_plain_string())
        false
      } catch {
        _ => true
      },
    )
  }
  assert_eq(
    @types.CqlDecimal::from_string("-0.0100").to_plain_string(),
    "-0.0100",
  )
  assert_true(
    try {
      ignore(
        @types.CqlUuid::from_string("00000000-0000-0000-0000-00000000000g"),
      )
      false
    } catch {
      _ => true
    },
  )
}
