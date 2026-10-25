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
async fn handshake(
  socket : Peer,
  auth? : Bool = false,
  throw_on_overload? : Bool,
  options_barrier? : FaultBarrier,
  startup_barrier? : FaultBarrier,
  auth_barrier? : FaultBarrier,
) -> Unit {
  let options = receive(socket)
  assert_eq(options.header.opcode, 5)
  if options_barrier is Some(barrier) {
    barrier.arrive()
  }
  let w = @codec.Writer::new()
  w.u16(if socket.compressed { 2 } else { 1 })
  w.string("CQL_VERSION")
  w.u16(1)
  w.string("3.0.0")
  if socket.compressed {
    w.string("COMPRESSION")
    w.u16(1)
    w.string("lz4")
  }
  respond(socket, options.header.stream, 6, w.to_bytes())
  let startup = receive(socket)
  assert_eq(startup.header.opcode, 1)
  if startup_barrier is Some(barrier) {
    barrier.arrive()
  }
  if throw_on_overload is Some(expected) {
    let r = @codec.Reader::new(startup.body)
    let entries : Map[String, String] = Map([])
    for _ in 0..<r.u16() {
      let key = r.string()
      entries[key] = r.string()
    }
    assert_eq(
      entries.get("THROW_ON_OVERLOAD"),
      if expected {
        Some("1")
      } else {
        None
      },
    )
    r.finish()
  }
  if auth {
    let w = @codec.Writer::new()
    w.string("org.apache.cassandra.auth.PasswordAuthenticator")
    respond(socket, startup.header.stream, 3, w.to_bytes())
    socket.framed = true
    let credentials = receive(socket)
    assert_eq(credentials.header.opcode, 15)
    assert_eq(
      @codec.Reader::new(credentials.body).bytes(),
      Some(b"\x00user\x00secret"),
    )
    if auth_barrier is Some(barrier) {
      barrier.arrive()
    }
    respond(socket, credentials.header.stream, 16, b"\xff\xff\xff\xff")
  } else {
    respond(socket, startup.header.stream, 2, b"")
    socket.framed = true
  }
}

///|
suberror FixtureFailure {
  FixtureFailure(String)
}

///|
// 每个屏障都有自己的总期限；失败说明包含协议阶段，不依赖固定 sleep。
struct FaultBarrier {
  phase : String
  reached : @async.Queue[Unit]
  resumed : @async.Queue[Unit]
  timeout_ms : Int
}

///|
fn FaultBarrier::new(phase : String, timeout_ms? : Int = 3000) -> FaultBarrier {
  {
    phase,
    reached: @async.Queue(kind=Blocking(1)),
    resumed: @async.Queue(kind=Blocking(1)),
    timeout_ms,
  }
}

///|
async fn FaultBarrier::arrive(self : FaultBarrier) -> Unit {
  @async.with_timeout(
    self.timeout_ms,
    () => {
      self.reached.put(())
      self.resumed.get()
    },
    error=FixtureFailure("barrier release timeout: \{self.phase}"),
  )
}

///|
async fn FaultBarrier::wait(self : FaultBarrier) -> Unit {
  @async.with_timeout(
    self.timeout_ms,
    () => self.reached.get(),
    error=FixtureFailure("barrier arrival timeout: \{self.phase}"),
  )
}

///|
async fn FaultBarrier::release(self : FaultBarrier) -> Unit {
  @async.with_timeout(
    self.timeout_ms,
    () => self.resumed.put(()),
    error=FixtureFailure("barrier resume timeout: \{self.phase}"),
  )
}

///|
async fn Peer::write_chunks(
  self : Peer,
  bytes : Bytes,
  width : Int,
  after_first? : FaultBarrier,
) -> Unit {
  if width < 1 {
    raise FixtureFailure("chunk width must be positive")
  }
  let mut position = 0
  while position < bytes.length() {
    let remaining = bytes.length() - position
    let end = position + (if remaining < width { remaining } else { width })
    self.write(bytes[position:end].to_owned())
    if position == 0 && after_first is Some(barrier) {
      barrier.arrive()
    }
    position = end
  }
}
