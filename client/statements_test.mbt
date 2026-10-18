///|
fn prepared_result(id : Bytes) -> Bytes raise @codec.CodecError {
  let w = @codec.Writer::new()
  w.i32(4)
  w.short_bytes(id)
  w.short_bytes(b"metadata")
  w.i32(1)
  w.i32(1)
  w.i32(1)
  w.u16(0)
  w.string("ks")
  w.string("t")
  w.string("id")
  w.u16(9)
  w.i32(1)
  w.i32(1)
  w.string("ks")
  w.string("t")
  w.string("id")
  w.u16(9)
  w.to_bytes()
}

///|
fn rows_result(
  values : Array[Int],
  state : Bytes?,
  omit_metadata? : Bool = false,
) -> Bytes raise @codec.CodecError {
  let w = @codec.Writer::new()
  w.i32(2)
  w.i32(
    (if omit_metadata { 4 } else { 1 }) | (if state is Some(_) { 2 } else { 0 }),
  )
  w.i32(1)
  if state is Some(_) {
    w.bytes(state)
  }
  if !omit_metadata {
    w.string("ks")
    w.string("t")
    w.string("id")
    w.u16(9)
  }
  w.i32(values.length())
  for value in values {
    @types.write_value(w, Integer(value))
  }
  w.to_bytes()
}

///|
async test "prepared cache validates bindings and recovers UNPREPARED once" {
  let bindings : Array[@types.Value] = [Integer(7)]
  @async.with_task_group(group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let worker = group.spawn(() => {
      let (tcp, _) = server.accept()
      let socket = Peer::new(tcp)
      defer socket.close()
      handshake(socket)
      let prepare = receive(socket)
      assert_eq(prepare.header.opcode, 9)
      respond(socket, prepare.header.stream, 8, prepared_result(b"old"))
      let execute = receive(socket)
      assert_eq(execute.header.opcode, 10)
      // 模拟调用方在网络等待期间修改原数组，恢复时仍应使用最初的参数。
      bindings[0] = Integer(99)
      let w = @codec.Writer::new()
      w.i32(0x2500)
      w.string("missing")
      w.short_bytes(b"old")
      respond(socket, execute.header.stream, 0, w.to_bytes())
      let prepare_again = receive(socket)
      assert_eq(prepare_again.header.opcode, 9)
      respond(socket, prepare_again.header.stream, 8, prepared_result(b"new"))
      let execute_again = receive(socket)
      assert_eq(execute_again.header.opcode, 10)
      let r = @codec.Reader::new(execute_again.body)
      assert_eq(r.short_bytes(), b"new")
      assert_eq(r.short_bytes(), b"metadata")
      ignore(r.u16())
      ignore(r.i32())
      assert_eq(r.u16(), 1)
      assert_eq(r.bytes(), Some(b"\x00\x00\x00\x07"))
      respond(socket, execute_again.header.stream, 8, rows_result([7], None))
    })
    @client.with_connection(
      config=@client.Config::new(port=server.addr.port()),
      connection => {
        let statement = connection.prepare("SELECT id FROM ks.t WHERE id=?")
        ignore(connection.prepare("SELECT id FROM ks.t WHERE id=?"))
        assert_true(
          try {
            ignore(statement.execute([]))
            false
          } catch {
            @client.Configuration(_) => true
            _ => false
          },
        )
        assert_true(
          try {
            ignore(statement.execute([Text("wrong type")]))
            false
          } catch {
            @codec.CodecError(_) => true
            _ => false
          },
        )
        guard statement.execute(bindings) is Rows(page) else {
          fail("expected row")
        }
        assert_eq(page.get(0, "id"), @types.Value::Integer(7))
      },
    )
    worker.wait()
  })
}

///|
async test "pager continues after an empty page and preserves bound values" {
  @async.with_task_group(group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let worker = group.spawn(() => {
      let (tcp, _) = server.accept()
      let socket = Peer::new(tcp)
      defer socket.close()
      handshake(socket)
      for i = 0; i < 2; i = i + 1 {
        let request = receive(socket)
        let r = @codec.Reader::new(request.body)
        assert_eq(r.long_string(), "SELECT id FROM ks.t WHERE id=?")
        assert_eq(r.u16(), 10)
        assert_eq(r.i32(), if i == 0 { 5 } else { 15 })
        assert_eq(r.u16(), 1)
        assert_eq(r.bytes(), Some(b"\x00\x00\x00\x2a"))
        assert_eq(r.i32(), 2)
        if i == 1 {
          assert_eq(r.bytes(), Some(b"next"))
        }
        r.finish()
        respond(
          socket,
          request.header.stream,
          8,
          if i == 0 {
            rows_result([], Some(b"next"))
          } else {
            rows_result([42], None, omit_metadata=true)
          },
        )
      }
      assert_eq(socket.read_some(), None)
    })
    @client.with_connection(
      config=@client.Config::new(port=server.addr.port()),
      connection => {
        let bindings : Array[@types.Value] = [Integer(42)]
        let pager = connection.pages(
          "SELECT id FROM ks.t WHERE id=?",
          values=bindings,
          options=@protocol.QueryOptions::new(page_size=2, skip_metadata=true),
        )
        bindings[0] = Integer(99)
        guard pager.next() is Some(empty) else { fail("expected first page") }
        assert_eq(empty.rows.length(), 0)
        // 调用方修改公开列数组不能污染下一页省略元数据时使用的缓存。
        empty.columns.clear()
        guard pager.next() is Some(page) else { fail("expected second page") }
        assert_eq(page.get(0, "id"), @types.Value::Integer(42))
        assert_true(pager.next() is None)
      },
    )
    worker.wait()
  })
}
