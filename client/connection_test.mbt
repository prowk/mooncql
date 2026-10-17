///|
async fn receive(socket : @socket.Tcp) -> @protocol.Frame {
  let header = @protocol.decode_header(socket.read_exactly(9))
  { header, body: socket.read_exactly(header.length), }
}

///|
async fn respond(
  socket : @socket.Tcp,
  stream : Int,
  opcode : Int,
  body : Bytes,
) -> Unit {
  socket.write(@protocol.encode_frame(stream, opcode, body, response=true))
}

///|
async fn handshake(socket : @socket.Tcp, auth? : Bool = false) -> Unit {
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
  if auth {
    let w = @codec.Writer::new()
    w.string("org.apache.cassandra.auth.PasswordAuthenticator")
    respond(socket, startup.header.stream, 3, w.to_bytes())
    let credentials = receive(socket)
    assert_eq(credentials.header.opcode, 15)
    assert_eq(
      @codec.Reader::new(credentials.body).bytes(),
      Some(b"\x00user\x00secret"),
    )
    respond(socket, credentials.header.stream, 16, b"\xff\xff\xff\xff")
  } else {
    respond(socket, startup.header.stream, 2, b"")
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
      let (socket, _) = server.accept()
      defer socket.close()
      handshake(socket)
      let first = receive(socket)
      let second = receive(socket)
      assert_true(first.header.stream != second.header.stream)
      let first_name = @codec.Reader::new(first.body).long_string()
      let second_name = @codec.Reader::new(second.body).long_string()
      let w = @codec.Writer::new()
      w.raw(
        @protocol.encode_frame(
          second.header.stream,
          8,
          named_result(second_name),
          response=true,
        ),
      )
      w.raw(@protocol.encode_frame(-1, 12, b"ignored event", response=true))
      w.raw(
        @protocol.encode_frame(
          first.header.stream,
          8,
          named_result(first_name),
          response=true,
        ),
      )
      let bytes = w.to_bytes()
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
      let (socket, _) = server.accept()
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
        let (socket, _) = server.accept()
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
        let (socket, _) = server.accept()
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
async test "request timeout closes connection and does not replay writes" {
  @async.with_timeout(2000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        let (socket, _) = server.accept()
        defer socket.close()
        handshake(socket)
        ignore(receive(socket))
        assert_eq(socket.read_some(), None)
      })
      @client.with_connection(
        config=@client.Config::new(port=server.addr.port(), timeout_ms=200),
        connection => {
          let timed_out = try {
            ignore(connection.query("write"))
            false
          } catch {
            @client.RequestTimedOut => true
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
