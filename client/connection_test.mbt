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
      w.raw(
        @protocol.encode_envelope(-1, 12, status_event(true), response=true),
      )
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
