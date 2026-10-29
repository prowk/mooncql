///|
fn split_random(state : Array[UInt32], bound : Int32) -> Int32 {
  state[0] = state[0] * 1664525U + 1013904223U
  ((state[0] >> 1) % bound.reinterpret_as_uint()).reinterpret_as_int()
}

///|
test "fixed seed arbitrary envelope splits preserve payload and detect frame corruption" {
  let random = [2026101819U]
  for sample in 0..<40 {
    let size = if sample < 2 { 400000 } else { split_random(random, 20000) }
    let body = Bytes::from_array(
      Array::makei(size, _ => split_random(random, 256).to_byte()),
    )
    let stream = split_random(random, 32768)
    let envelope = @protocol.encode_envelope(stream, 8, body, response=true)
    for compressed in [false, true] {
      let decoder = @protocol.EnvelopeDecoder::new(max_body=400000)
      let messages = []
      let mut position = 0
      while position < envelope.length() {
        let remaining = envelope.length() - position
        let width = 1 + split_random(random, 131071)
        let end = position + (if width < remaining { width } else { remaining })
        let encoded = @framing.encode(
          envelope[position:end].to_owned(),
          self_contained=false,
          compressed~,
        )
        for message in decoder.feed(@framing.decode(encoded, compressed~)) {
          messages.push(message)
        }
        let damaged = encoded.to_array()
        let corrupt_at = split_random(random, damaged.length())
        damaged[corrupt_at] = (damaged[corrupt_at].to_int() ^
        (1 << split_random(random, 8))).to_byte()
        assert_true(
          try {
            ignore(@framing.decode(Bytes::from_array(damaged), compressed~))
            false
          } catch {
            _ => true
          },
        )
        position = end
      }
      assert_eq(messages.length(), 1)
      assert_eq(messages[0].header.stream, stream)
      assert_eq(messages[0].header.length, size)
      assert_eq(messages[0].body, body)
    }
  }
}
