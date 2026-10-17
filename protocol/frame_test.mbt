///|
test "query frame matches v5 envelope header" {
  let bytes = @protocol.encode_envelope(3, 7, b"abc")
  assert_eq(bytes, b"\x05\x00\x00\x03\x07\x00\x00\x00\x03abc")
  let frame = @protocol.decode_message_envelope(bytes)
  assert_eq(frame.header.stream, 3)
  assert_eq(frame.body, b"abc")
}

///|
test "event stream and response direction" {
  let frame = @protocol.decode_message_envelope(
    @protocol.encode_envelope(-1, 12, b"", response=true),
  )
  assert_eq(frame.header.stream, -1)
  assert_true(frame.header.response)
}

///|
test "reject invalid version oversized and partial frames" {
  for
    bytes in [
      b"\x03\x00\x00\x00\x02\x00\x00\x00\x00", b"\x85\x00\x00\x00\x02\x7f\xff\xff\xff",
      b"\x85\x00\x00\x00\x02\x00\x00\x00\x01",
    ] {
    assert_true(
      try {
        ignore(@protocol.decode_message_envelope(bytes))
        false
      } catch {
        _ => true
      },
    )
  }
}

///|
test "consume tracing warnings and custom payload before message" {
  let w = @codec.Writer::new()
  w.raw(b"0123456789abcdef")
  w.u16(1)
  w.string("警告")
  w.u16(1)
  w.string("key")
  w.bytes(Some(b"value"))
  w.raw(b"message")
  let frame = @protocol.decode_message_envelope(
    @protocol.encode_envelope(1, 8, w.to_bytes(), response=true, flags=14),
  )
  let envelope = @protocol.decode_payload(frame)
  assert_eq(envelope.tracing_id, Some(b"0123456789abcdef"))
  assert_eq(envelope.warnings, ["警告"])
  assert_eq(envelope.custom_payload.get("key"), Some(Some(b"value")))
  assert_eq(envelope.message, b"message")
}
