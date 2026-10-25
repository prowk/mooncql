///|
struct Peer {
  tcp : @socket.Tcp
  mut framed : Bool
  compressed : Bool
  decoder : @protocol.EnvelopeDecoder
  mut messages : Array[@protocol.MessageEnvelope]
  mut position : Int
}

///|
fn Peer::new(tcp : @socket.Tcp, compressed? : Bool = false) -> Peer {
  {
    tcp,
    framed: false,
    compressed,
    decoder: @protocol.EnvelopeDecoder::new(),
    messages: [],
    position: 0,
  }
}

///|
fn Peer::close(self : Peer) -> Unit {
  self.tcp.close()
}

///|
async fn Peer::read_some(self : Peer) -> Bytes? {
  self.tcp.read_some()
}

///|
async fn Peer::write(self : Peer, bytes : Bytes) -> Unit {
  self.tcp.write(bytes)
}

///|
async fn receive(socket : Peer) -> @protocol.MessageEnvelope {
  if !socket.framed {
    let header = @protocol.decode_envelope_header(socket.tcp.read_exactly(9))
    return { header, body: socket.tcp.read_exactly(header.length), }
  }
  while socket.position == socket.messages.length() {
    let header = @framing.decode_header(
      socket.tcp.read_exactly(if socket.compressed { 8 } else { 6 }),
      compressed=socket.compressed,
    )
    socket.messages = socket.decoder.feed(
      @framing.decode_payload(
        header,
        socket.tcp.read_exactly(header.payload_length + 4),
      ),
    )
    socket.position = 0
  }
  let message = socket.messages[socket.position]
  socket.position += 1
  message
}

///|
async fn respond(
  socket : Peer,
  stream : Int,
  opcode : Int,
  body : Bytes,
) -> Unit {
  let envelope = @protocol.encode_envelope(stream, opcode, body, response=true)
  if socket.framed {
    for frame in @framing.split(envelope, compressed=socket.compressed) {
      socket.write(frame)
    }
  } else {
    socket.write(envelope)
  }
}

///|
// 与测试 Peer 使用同一 framing 边界，基准只需要无认证握手。
async fn handshake(socket : Peer) -> Unit {
  let options = receive(socket)
  assert_eq(options.header.opcode, 5)
  let w = @codec.Writer::new()
  w.u16(1)
  w.string("CQL_VERSION")
  w.u16(1)
  w.string("3.0.0")
  respond(socket, options.header.stream, 6, w.to_bytes())
  let startup = receive(socket)
  assert_eq(startup.header.opcode, 1)
  respond(socket, startup.header.stream, 2, b"")
  socket.framed = true
}
