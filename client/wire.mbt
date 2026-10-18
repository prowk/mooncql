///|
struct Wire {
  socket : Transport
  max_body : Int
  compressed : Bool
  mut framed : Bool
  decoder : @protocol.EnvelopeDecoder
  mut messages : Array[@protocol.MessageEnvelope]
  mut position : Int
}

///|
fn Wire::new(socket : Transport, max_body : Int, compressed : Bool) -> Wire {
  {
    socket,
    max_body,
    compressed,
    framed: false,
    decoder: @protocol.EnvelopeDecoder::new(max_body~),
    messages: [],
    position: 0,
  }
}

///|
async fn Wire::send(
  self : Wire,
  stream : Int,
  request : @protocol.Request,
  on_write? : () -> Unit = () => (),
) -> Unit {
  let bytes = @protocol.encode_envelope(
    stream,
    request.opcode,
    request.body,
    flags=request.flags,
  )
  if self.framed {
    // 调用方持有写锁，保证同一消息的各个分片连续发送。
    let mut offset = 0
    while offset < bytes.length() {
      let remaining = bytes.length() - offset
      let length = if remaining > 131071 { 131071 } else { remaining }
      let frame = @framing.encode(
        bytes[offset:offset + length].to_owned(),
        self_contained=bytes.length() <= 131071,
        compressed=self.compressed,
      )
      on_write()
      self.socket.write(frame)
      offset += length
    }
  } else {
    on_write()
    self.socket.write(bytes)
  }
}

///|
async fn Wire::receive(self : Wire) -> @protocol.MessageEnvelope {
  let envelope = if !self.framed {
    let header = @protocol.decode_envelope_header(
      self.socket.read_exactly(9),
      max_body=self.max_body,
    )
    @protocol.MessageEnvelope::{
      header,
      body: self.socket.read_exactly(header.length),
    }
  } else {
    while self.position == self.messages.length() {
      // 先验证帧头校验，再按照已验证的长度读取载荷。
      let header = @framing.decode_header(
        self.socket.read_exactly(if self.compressed { 8 } else { 6 }),
        compressed=self.compressed,
      )
      let frame = @framing.decode_payload(
        header,
        self.socket.read_exactly(header.payload_length + 4),
      )
      self.messages = self.decoder.feed(frame)
      self.position = 0
    }
    let message = self.messages[self.position]
    self.position += 1
    message
  }
  if !envelope.header.response {
    raise Unexpected("server sent request envelope")
  }
  envelope
}
