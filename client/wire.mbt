///|
struct Wire {
  socket : Transport
  max_body : Int32
  compressed : Bool
  mut framed : Bool
  decoder : @protocol.EnvelopeDecoder
  mut messages : Array[@protocol.MessageEnvelope]
  mut position : Int32
  mut queued_bytes : Int64
  mut peak_bytes : Int64
  metrics : Metrics?
}

///|
fn Wire::new(
  socket : Transport,
  max_body : Int32,
  compressed : Bool,
  metrics : Metrics?,
) -> Wire {
  {
    socket,
    max_body,
    compressed,
    framed: false,
    decoder: @protocol.EnvelopeDecoder::new(max_body~),
    messages: [],
    position: 0,
    queued_bytes: 0L,
    peak_bytes: 0L,
    metrics,
  }
}

///|
async fn Wire::send(
  self : Wire,
  stream : Int32,
  request : @protocol.Request,
  on_write~ : () -> Unit = () => (),
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
      if self.metrics is Some(metrics) {
        metrics.data.sent_frames += 1L
        metrics.data.sent_raw_payload_bytes += length.to_int64()
        metrics.data.sent_encoded_payload_bytes += (frame.length() -
        (if self.compressed { 8 } else { 6 }) -
        4).to_int64()
        metrics.data.sent_complete_frame_bytes += frame.length().to_int64()
      }
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
      if self.metrics is Some(metrics) {
        metrics.data.received_frames += 1L
        metrics.data.received_raw_payload_bytes += frame.payload
          .length()
          .to_int64()
        metrics.data.received_encoded_payload_bytes += header.payload_length.to_int64()
        metrics.data.received_complete_frame_bytes += (header.payload_length +
        (if self.compressed { 8 } else { 6 }) +
        4).to_int64()
      }
      self.messages = self.decoder.feed(frame)
      self.position = 0
      self.queued_bytes = 0L
      for message in self.messages {
        self.queued_bytes += message.body.length().to_int64()
      }
      let buffered = self.queued_bytes + self.decoder.buffered_bytes()
      if buffered > self.peak_bytes {
        self.peak_bytes = buffered
      }
    }
    let message = self.messages[self.position]
    // 已交出的正文不能继续被 messages 的旧槽引用。
    self.messages[self.position] = { header: message.header, body: b"", }
    self.queued_bytes -= message.body.length().to_int64()
    self.position += 1
    if self.position == self.messages.length() {
      self.messages.clear()
      self.position = 0
    }
    message
  }
  if !envelope.header.response {
    raise Unexpected("server sent request envelope")
  }
  envelope
}
