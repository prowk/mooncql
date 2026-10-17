///|
test "v5 envelope extensions preserve recognized fields" {
  let envelope = @protocol.decode_message_envelope(
    b"\x85\x41\x00\x00\x02\x00\x00\x00\x03\xaa\xbb\xcc",
  )
  assert_eq(envelope.header.flags, 65)
  assert_true(
    @protocol.decode_response(2, @protocol.decode_payload(envelope).message)
    is Ready,
  )
  let w = @codec.Writer::new()
  w.u16(1)
  w.string("CQL_VERSION")
  w.u16(1)
  w.string("3.0.0")
  w.raw(b"future extension")
  guard @protocol.decode_response(6, w.to_bytes()) is Supported(supported) else {
    fail("missing supported")
  }
  assert_eq(supported.get("CQL_VERSION"), Some(["3.0.0"]))
  let w = @codec.Writer::new()
  w.i32(0x2200)
  w.string("invalid query")
  w.raw(b"future detail")
  let error = @protocol.decode_error(w.to_bytes())
  assert_eq(error.message, "invalid query")
  assert_true(error.detail is Other(b"future detail"))
}

///|
test "v5 self contained and fragmented boundary is 131071 payload bytes" {
  for size in [131070, 131071, 131072, 262142, 262143] {
    let payload = Bytes::from_array(
      Array::makei(size - 9, i => (i % 251).to_byte()),
    )
    let envelope = @protocol.encode_envelope(7, 8, payload, response=true)
    for compressed in [false, true] {
      let decoder = @protocol.EnvelopeDecoder::new()
      let mut count = 0
      for bytes in @framing.split(envelope, compressed~) {
        let frame = @framing.decode(bytes, compressed~)
        assert_eq(frame.header.self_contained, size <= 131071)
        for decoded in decoder.feed(frame) {
          count += 1
          assert_eq(decoded.header.stream, 7)
          assert_eq(decoded.body, payload)
        }
      }
      assert_eq(count, 1)
    }
  }
}

///|
test "v5 result extension is ignored inside complete envelope" {
  let w = @codec.Writer::new()
  w.i32(2)
  w.i32(1)
  w.i32(1)
  w.string("ks")
  w.string("t")
  w.string("value")
  w.u16(9)
  w.i32(1)
  @types.write_value(w, Integer(42))
  w.raw(b"future result extension")
  guard @protocol.decode_result(w.to_bytes()) is Rows(page) else {
    fail("expected rows")
  }
  assert_eq(page.get(0, "value"), @types.Value::Integer(42))
}
