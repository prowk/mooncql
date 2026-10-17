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
) -> Unit {
  let options = receive(socket)
  assert_eq(options.header.opcode, 5)
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
    respond(socket, credentials.header.stream, 16, b"\xff\xff\xff\xff")
  } else {
    respond(socket, startup.header.stream, 2, b"")
    socket.framed = true
  }
}

///|
fn named_result(name : String) -> Bytes raise @codec.CodecError {
  let w = @codec.Writer::new()
  w.i32(3)
  w.string(name)
  w.to_bytes()
}

///|
async test "multiplex correlates reversed responses across fragmented and coalesced frames" {
  @async.with_task_group(group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let worker = group.spawn(() => {
      let (tcp, _) = server.accept()
      let socket = Peer::new(tcp)
      defer socket.close()
      handshake(socket)
      let first = receive(socket)
      let second = receive(socket)
      assert_true(first.header.stream != second.header.stream)
      let first_name = @codec.Reader::new(first.body).long_string()
      let second_name = @codec.Reader::new(second.body).long_string()
      let w = @codec.Writer::new()
      w.raw(
        @protocol.encode_envelope(
          second.header.stream,
          8,
          named_result(second_name),
          response=true,
        ),
      )
      w.raw(@protocol.encode_envelope(-1, 12, b"ignored event", response=true))
      w.raw(
        @protocol.encode_envelope(
          first.header.stream,
          8,
          named_result(first_name),
          response=true,
        ),
      )
      let bytes = @framing.encode(w.to_bytes())
      socket.write(bytes[0:2].to_owned())
      socket.write(bytes[2:7].to_owned())
      socket.write(bytes[7:].to_owned())
    })
    @client.with_connection(
      config=@client.Config::new(port=server.addr.port()),
      connection => {
        let results = @async.all([
          () => connection.query("first"),
          () => connection.query("second"),
        ])
        assert_true(results[0] is SetKeyspace("first"))
        assert_true(results[1] is SetKeyspace("second"))
      },
    )
    worker.wait()
  })
}

///|
async test "password authentication sends correct PLAIN exchange" {
  @async.with_task_group(group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let worker = group.spawn(() => {
      let (tcp, _) = server.accept()
      let socket = Peer::new(tcp)
      defer socket.close()
      handshake(socket, auth=true)
      let query = receive(socket)
      respond(socket, query.header.stream, 8, b"\x00\x00\x00\x01")
    })
    @client.with_connection(
      config=@client.Config::new(
        port=server.addr.port(),
        username="user",
        password="secret",
      ),
      connection => assert_true(connection.query("query") is Void),
    )
    worker.wait()
  })
}

///|
async test "EOF completes every pending request without hanging" {
  @async.with_timeout(2000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let socket = Peer::new(tcp)
        defer socket.close()
        handshake(socket)
        ignore(receive(socket))
        ignore(receive(socket))
      })
      @client.with_connection(
        config=@client.Config::new(port=server.addr.port()),
        connection => {
          let failed = @async.all([
            () => {
              try {
                ignore(connection.query("a"))
                false
              } catch {
                _ => true
              }
            },
            () => {
              try {
                ignore(connection.query("b"))
                false
              } catch {
                _ => true
              }
            },
          ])
          assert_eq(failed, [true, true])
          assert_true(connection.is_closed())
        },
      )
      worker.wait()
    })
  })
}

///|
async test "scope exit cancels idle reader before closing socket handle" {
  @async.with_timeout(2000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let socket = Peer::new(tcp)
        defer socket.close()
        handshake(socket)
        let query = receive(socket)
        respond(socket, query.header.stream, 8, b"\x00\x00\x00\x01")
        // 保持服务端连接打开，确保客户端自行取消仍在等待的读任务。
        assert_eq(socket.read_some(), None)
      })
      @client.with_connection(
        config=@client.Config::new(port=server.addr.port()),
        connection => assert_true(connection.query("query") is Void),
      )
      worker.wait()
    })
  })
}

///|
async test "zero abandoned budget closes on sent timeout without replaying writes" {
  @async.with_timeout(2000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let socket = Peer::new(tcp)
        defer socket.close()
        handshake(socket)
        ignore(receive(socket))
        assert_eq(socket.read_some(), None)
      })
      @client.with_connection(
        config=@client.Config::new(
          port=server.addr.port(),
          timeout_ms=200,
          max_abandoned=0,
        ),
        connection => {
          let timed_out = try {
            ignore(connection.query("write"))
            false
          } catch {
            @client.TimedOut(_) => true
            _ => false
          }
          assert_true(timed_out)
          assert_true(connection.is_closed())
          assert_true(
            try {
              ignore(connection.query("another"))
              false
            } catch {
              @client.Closed => true
              _ => false
            },
          )
        },
      )
      worker.wait()
    })
  })
}
