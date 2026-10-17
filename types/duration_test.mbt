///|
test "duration independent signed vint fixtures and boundaries" {
  let fixtures : Array[(@types.Value, Bytes)] = [
    (Duration(1, 2, 3L), b"\x02\x04\x06"),
    (Duration(-1, -2, -3L), b"\x01\x03\x05"),
    (Duration(64, 128, 8192L), b"\x80\x80\x81\x00\xc0\x40\x00"),
    (
      Duration(2147483647, 2147483647, 9223372036854775807L),
      b"\xf0\xff\xff\xff\xfe\xf0\xff\xff\xff\xfe\xff\xff\xff\xff\xff\xff\xff\xff\xfe",
    ),
    (
      Duration(-2147483648, -2147483648, -9223372036854775808L),
      b"\xf0\xff\xff\xff\xff\xf0\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff",
    ),
  ]
  // 期望字节由 cassandra-driver 的 DurationType 独立生成。
  for (value, bytes) in fixtures {
    assert_eq(@types.encode_value(value), bytes)
    assert_eq(@types.decode_value(Duration, Some(bytes)), value)
    @types.validate(Duration, value)
  }
  assert_eq(
    @types.read_type(@codec.Reader::new(b"\x00\x15")),
    @types.CqlType::Duration,
  )
}

///|
test "duration rejects mixed signs truncation and overflowing month count" {
  for value in [@types.Value::Duration(1, -1, 0L), Duration(0, 1, -1L)] {
    assert_true(
      try {
        ignore(@types.encode_value(value))
        false
      } catch {
        _ => true
      },
    )
  }
  for
    bytes in [
      b"", b"\x00\x00", b"\x00\x00\xff", b"\x02\x01\x00", b"\xf1\x00\x00\x00\x00\x00\x00",
    ] {
    assert_true(
      try {
        ignore(@types.decode_value(Duration, Some(bytes)))
        false
      } catch {
        _ => true
      },
    )
  }
}
