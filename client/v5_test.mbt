///|
async test "v5 metadata cache updates and ignores stale concurrent executions" {
  @async.with_timeout(3000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let socket = Peer::new(tcp)
        defer socket.close()
        handshake(socket)
        let prepare = receive(socket)
        respond(socket, prepare.header.stream, 8, prepared_result(b"id"))
        let first = receive(socket)
        let second = receive(socket)
        for
          (request, id, typ, value) in [
            (first, b"new", 13, @types.Value::Text("new")),
            (second, b"stale", 2, @types.Value::BigInteger(7L)),
          ] {
          let r = @codec.Reader::new(request.body)
          assert_eq(r.short_bytes(), b"id")
          assert_eq(r.short_bytes(), b"metadata")
          let w = @codec.Writer::new()
          w.i32(2)
          w.i32(9)
          w.i32(1)
          w.short_bytes(id)
          w.string("ks")
          w.string("t")
          w.string("value")
          w.u16(typ)
          w.i32(1)
          @types.write_value(w, value)
          respond(socket, request.header.stream, 8, w.to_bytes())
        }
        let next = receive(socket)
        let r = @codec.Reader::new(next.body)
        assert_eq(r.short_bytes(), b"id")
        assert_eq(r.short_bytes(), b"new")
        let w = @codec.Writer::new()
        w.i32(2)
        w.i32(4)
        w.i32(1)
        w.i32(1)
        @types.write_value(w, Text("cached"))
        respond(socket, next.header.stream, 8, w.to_bytes())
      })
      @client.with_connection_builder(
        config=@client.ConnectionBuilder::new(port=server.addr.port()),
        connection => {
          let statement = connection.prepare("query")
          let results = @async.all([
            () => statement.execute([Integer(1)]),
            () => statement.execute([Integer(2)]),
          ])
          assert_eq(results.length(), 2)
          guard statement.execute(
              [Integer(3)],
              options=@protocol.QueryOptions::new(skip_metadata=true),
            )
            is Rows(page) else {
            fail("expected cached rows")
          }
          assert_eq(page.get(0, "value"), @types.Value::Text("cached"))
        },
      )
      worker.wait()
    })
  })
}

///|
async test "prepared cache separates identical text by explicit keyspace" {
  @async.with_task_group(group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let worker = group.spawn(() => {
      let (tcp, _) = server.accept()
      let socket = Peer::new(tcp)
      defer socket.close()
      handshake(socket)
      for keyspace in ["one", "two"] {
        let request = receive(socket)
        let r = @codec.Reader::new(request.body)
        assert_eq(r.long_string(), "query")
        assert_eq(r.i32(), 1)
        assert_eq(r.string(), keyspace)
        r.finish()
        respond(socket, request.header.stream, 8, prepared_result(b"id"))
      }
    })
    @client.with_connection_builder(
      config=@client.ConnectionBuilder::new(port=server.addr.port()),
      connection => {
        ignore(connection.prepare("query", keyspace="one"))
        ignore(connection.prepare("query", keyspace="one"))
        ignore(connection.prepare("query", keyspace="two"))
      },
    )
    worker.wait()
  })
}

///|
async test "v5 LZ4 authentication large request and large response" {
  let payload = Bytes::from_array(
    Array::makei(300000, i => (i % 251).to_byte()),
  )
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let socket = Peer::new(tcp, compressed=true)
        defer socket.close()
        handshake(socket, auth=true)
        let query = receive(socket)
        let r = @codec.Reader::new(query.body)
        assert_eq(r.long_string(), "query")
        assert_eq(r.u16(), 10)
        assert_eq(r.i32(), 1)
        assert_eq(r.u16(), 1)
        assert_eq(r.bytes(), Some(payload))
        r.finish()
        let w = @codec.Writer::new()
        w.i32(2)
        w.i32(1)
        w.i32(1)
        w.string("ks")
        w.string("table")
        w.string("data")
        w.u16(3)
        w.i32(1)
        w.bytes(Some(payload))
        respond(socket, query.header.stream, 8, w.to_bytes())
      })
      @client.with_connection_builder(
        config=@client.ConnectionBuilder::new(
          port=server.addr.port(),
          username="user",
          password="secret",
          compression=true,
        ),
        connection => {
          guard connection.query("query", values=[Bytes(payload)]) is Rows(page) else {
            fail("expected rows")
          }
          assert_eq(page.get(0, "data"), @types.Value::Bytes(payload))
        },
      )
      worker.wait()
    })
  })
}

///|
async test "v5 payload CRC failure closes pending requests" {
  @async.with_timeout(3000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let socket = Peer::new(tcp)
        defer socket.close()
        handshake(socket)
        let query = receive(socket)
        let bytes = @framing.encode(
          @protocol.encode_envelope(
            query.header.stream,
            8,
            b"\x00\x00\x00\x01",
            response=true,
          ),
        ).to_array()
        bytes[6] = (bytes[6].to_int() ^ 1).to_byte()
        socket.write(Bytes::from_array(bytes))
        assert_eq(socket.read_some(), None)
      })
      @client.with_connection_builder(
        config=@client.ConnectionBuilder::new(port=server.addr.port()),
        connection => {
          assert_true(
            try {
              ignore(connection.query("query"))
              false
            } catch {
              _ => true
            },
          )
          assert_true(connection.is_closed())
        },
      )
      worker.wait()
    })
  })
}
