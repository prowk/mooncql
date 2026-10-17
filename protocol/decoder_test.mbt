///|
test "v5 reassembly permits every header split and coalesced envelopes" {
  let message = @protocol.encode_envelope(4, 8, b"body", response=true)
  for split = 1; split < message.length(); split = split + 1 {
    let decoder = @protocol.EnvelopeDecoder::new()
    let first = @framing.decode(
      @framing.encode(message[0:split].to_owned(), self_contained=false),
    )
    assert_eq(decoder.feed(first).length(), 0)
    let last = @framing.decode(
      @framing.encode(message[split:].to_owned(), self_contained=false),
    )
    let messages = decoder.feed(last)
    assert_eq(messages.length(), 1)
    assert_eq(messages[0].body, b"body")
    assert_eq(messages[0].header.stream, 4)
    let w = @codec.Writer::new()
    w.raw(message)
    w.raw(message)
    assert_eq(
      decoder.feed(@framing.decode(@framing.encode(w.to_bytes()))).length(),
      2,
    )
  }
}

///|
test "v5 envelope reassembly enforces limits and self contained boundaries" {
  let message = @protocol.encode_envelope(4, 8, b"body", response=true)
  assert_true(
    try {
      ignore(
        @protocol.EnvelopeDecoder::new(max_body=3).feed(
          @framing.decode(@framing.encode(message)),
        ),
      )
      false
    } catch {
      _ => true
    },
  )
  for interrupted in [true, false] {
    let w = @codec.Writer::new()
    w.raw(message[8:].to_owned())
    w.raw(message)
    let decoder = @protocol.EnvelopeDecoder::new()
    ignore(
      decoder.feed(
        @framing.decode(
          @framing.encode(message[0:8].to_owned(), self_contained=false),
        ),
      ),
    )
    assert_true(
      try {
        ignore(
          decoder.feed(
            @framing.decode(
              @framing.encode(
                if interrupted {
                  message
                } else {
                  w.to_bytes()
                },
                self_contained=interrupted,
              ),
            ),
          ),
        )
        false
      } catch {
        _ => true
      },
    )
  }
  assert_true(
    try {
      ignore(
        @protocol.EnvelopeDecoder::new().feed(
          @framing.decode(@framing.encode(message[0:10].to_owned())),
        ),
      )
      false
    } catch {
      _ => true
    },
  )
}
