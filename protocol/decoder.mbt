///|
pub struct EnvelopeDecoder {
  max_body : Int
  mut prefix : Bytes
  mut header : EnvelopeHeader?
  mut body : @codec.Writer
  mut received : Int
}

///|
pub fn EnvelopeDecoder::new(max_body? : Int = 16777216) -> EnvelopeDecoder {
  {
    max_body,
    prefix: b"",
    header: None,
    body: @codec.Writer::new(),
    received: 0,
  }
}

///|
/// 已保存的正文与不足九字节的 envelope 头；不表示 Writer 容量或进程 RSS。
pub fn EnvelopeDecoder::buffered_bytes(self : EnvelopeDecoder) -> Int64 {
  self.received.to_int64() + self.prefix.length().to_int64()
}

///|
pub fn EnvelopeDecoder::clear(self : EnvelopeDecoder) -> Unit {
  self.prefix = b""
  self.header = None
  self.body = @codec.Writer::new()
  self.received = 0
}

///|
pub fn EnvelopeDecoder::feed(
  self : EnvelopeDecoder,
  frame : @framing.Frame,
) -> Array[MessageEnvelope] raise @codec.CodecError {
  let messages = []
  let r = @codec.Reader::new(frame.payload)
  if frame.header.self_contained {
    if self.prefix.length() != 0 || self.header is Some(_) {
      raise @codec.CodecError(
        "self contained frame interrupts fragmented envelope",
      )
    }
    while r.remaining() > 0 {
      let header = decode_envelope_header(r.take(9), max_body=self.max_body)
      messages.push({ header, body: r.take(header.length), })
    }
    return messages
  }
  if self.header is None {
    let need = 9 - self.prefix.length()
    let w = @codec.Writer::new()
    w.raw(self.prefix)
    w.raw(r.take(if need < r.remaining() { need } else { r.remaining() }))
    self.prefix = w.to_bytes()
    if self.prefix.length() < 9 {
      return messages
    }
    self.header = Some(
      decode_envelope_header(self.prefix, max_body=self.max_body),
    )
  }
  guard self.header is Some(header) else {
    abort("missing decoded envelope header")
  }
  if r.remaining() > header.length - self.received {
    raise @codec.CodecError(
      "fragmented frame contains bytes from another envelope",
    )
  }
  self.received += r.remaining()
  self.body.raw(r.take(r.remaining()))
  if self.received == header.length {
    messages.push({ header, body: self.body.to_bytes(), })
    self.prefix = b""
    self.header = None
    self.body = @codec.Writer::new()
    self.received = 0
  }
  messages
}
