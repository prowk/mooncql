///|
fn conditional_rows(
  applied : Bool,
  current? : String,
) -> Bytes raise @codec.CodecError {
  let w = @codec.Writer::new()
  w.i32(2)
  w.i32(1)
  w.i32(if current is Some(_) { 2 } else { 1 })
  w.string("ks")
  w.string("t")
  w.string("[applied]")
  w.u16(4)
  if current is Some(_) {
    w.string("value")
    w.u16(13)
  }
  w.i32(1)
  @types.write_value(w, Boolean(applied))
  if current is Some(text) {
    @types.write_value(w, Text(text))
  }
  w.to_bytes()
}

///|
async test "LWT skip metadata uses each response and preserves prepared metadata ID" {
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
        for i = 0; i < 3; i = i + 1 {
          let execute = receive(socket)
          let r = @codec.Reader::new(execute.body)
          assert_eq(r.short_bytes(), b"id")
          assert_eq(r.short_bytes(), b"metadata")
          assert_eq(r.u16(), 10)
          assert_eq(r.i32(), 19)
          assert_eq(r.u16(), 1)
          ignore(r.bytes())
          assert_eq(r.u16(), if i == 1 { 9 } else { 8 })
          r.finish()
          respond(
            socket,
            execute.header.stream,
            8,
            conditional_rows(
              i != 1,
              current?=if i == 1 { Some("existing") } else { None },
            ),
          )
        }
        let query = receive(socket)
        respond(socket, query.header.stream, 8, rows_result([7], None))
      })
      @client.with_connection_builder(
        config=@client.ConnectionBuilder::new(port=server.addr.port()),
        connection => {
          let statement = connection.prepare("conditional")
          for i = 0; i < 3; i = i + 1 {
            let result = statement.execute_conditional(
              [Integer(1)],
              options=@protocol.QueryOptions::new(
                skip_metadata=true,
                serial_consistency=if i == 1 { LocalSerial } else { Serial },
              ),
            )
            assert_eq(result.applied, i != 1)
            assert_true(result.page.new_metadata_id is None)
            if i == 1 {
              assert_eq(
                result.page.get(0, "value"),
                @types.Value::Text("existing"),
              )
            }
          }
          guard connection.query("ordinary") is Rows(page) else {
            fail("expected ordinary row")
          }
          assert_eq(page.get(0, "id"), @types.Value::Integer(7))
        },
      )
      worker.wait()
    })
  })
}

///|
async test "conditional QUERY requests metadata even when skip metadata is requested" {
  @async.with_task_group(group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let worker = group.spawn(() => {
      let (tcp, _) = server.accept()
      let socket = Peer::new(tcp)
      defer socket.close()
      handshake(socket)
      let query = receive(socket)
      let r = @codec.Reader::new(query.body)
      assert_eq(r.long_string(), "conditional")
      assert_eq(r.u16(), 10)
      assert_eq(r.i32(), 16)
      assert_eq(r.u16(), 8)
      r.finish()
      respond(
        socket,
        query.header.stream,
        8,
        conditional_rows(false, current="existing"),
      )
    })
    @client.with_connection_builder(
      config=@client.ConnectionBuilder::new(port=server.addr.port()),
      connection => {
        let result = connection.query_conditional(
          "conditional",
          options=@protocol.QueryOptions::new(
            skip_metadata=true,
            serial_consistency=Serial,
          ),
        )
        assert_true(!result.applied)
        assert_eq(result.page.get(0, "value"), @types.Value::Text("existing"))
      },
    )
    worker.wait()
  })
}

///|
async test "conditional API rejects ordinary result instead of inventing applied status" {
  @async.with_task_group(group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let worker = group.spawn(() => {
      let (tcp, _) = server.accept()
      let socket = Peer::new(tcp)
      defer socket.close()
      handshake(socket)
      let query = receive(socket)
      respond(socket, query.header.stream, 8, rows_result([7], None))
      assert_eq(socket.read_some(), None)
    })
    @client.with_connection_builder(
      config=@client.ConnectionBuilder::new(port=server.addr.port()),
      connection => {
        assert_true(
          try {
            ignore(connection.query_conditional("ordinary"))
            false
          } catch {
            @client.Unexpected(_) => true
            _ => false
          },
        )
        assert_true(!connection.is_closed())
      },
    )
    worker.wait()
  })
}
