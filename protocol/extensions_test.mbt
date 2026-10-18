///|
test "request tracing and payload match independent v5 envelope bytes" {
  let options = @protocol.QueryOptions::new(
    request_options=@protocol.RequestOptions::new(
      tracing=true,
      custom_payload=Map([("tag", Some(b"x"))]),
    ),
  )
  let request = @protocol.query("SELECT 1", options~)
  assert_eq(request.flags, 6)
  assert_eq(
    @protocol.encode_envelope(
      3,
      request.opcode,
      request.body,
      flags=request.flags,
    ),
    b"\x05\x06\x00\x03\x07\x00\x00\x00\x1e\x00\x01\x00\x03tag\x00\x00\x00\x01x\x00\x00\x00\x08SELECT 1\x00\x0a\x00\x00\x00\x00",
  )
  let traced = @protocol.query(
    "SELECT 1",
    options=@protocol.QueryOptions::new(
      request_options=@protocol.RequestOptions::new(tracing=true),
    ),
  )
  assert_eq(traced.flags, 2)
  assert_eq(traced.body, @protocol.query("SELECT 1").body)
  assert_eq(@protocol.query("SELECT 1").flags, 0)
  let prepare = @protocol.prepare(
    "SELECT 1",
    request_options=@protocol.RequestOptions::new(tracing=true),
  )
  assert_eq(prepare.flags, 2)
  assert_true(
    try {
      ignore(
        @protocol.options().with_options(
          @protocol.RequestOptions::new(tracing=true),
        ),
      )
      false
    } catch {
      _ => true
    },
  )
}

///|
test "request options snapshot isolates mutable payload maps" {
  let payload = Map([("tag", Some(b"original"))])
  let request_options = @protocol.RequestOptions::new(custom_payload=payload)
  let options = @protocol.QueryOptions::new(request_options~)
  let snapshot = options.snapshot()
  payload["tag"] = Some(b"external change")
  request_options.custom_payload["tag"] = Some(b"request options change")
  options.request_options.unwrap().custom_payload["tag"] = Some(
    b"query options change",
  )
  let request = @protocol.query("q", options=snapshot)
  let r = @codec.Reader::new(request.body)
  assert_eq(r.u16(), 1)
  assert_eq(r.string(), "tag")
  assert_eq(r.bytes(), Some(b"original"))
}
