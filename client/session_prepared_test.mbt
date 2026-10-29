///|
fn session_metadata(
  id : Bytes,
  metadata : Bytes,
  column : String,
) -> Bytes raise {
  let w = @codec.Writer::new()
  w.i32(4)
  w.short_bytes(id)
  w.short_bytes(metadata)
  w.i32(1)
  w.i32(1)
  w.i32(1)
  w.u16(0)
  w.string("ks")
  w.string("t")
  w.string("arg")
  w.u16(9)
  w.i32(1)
  w.i32(1)
  w.string("ks")
  w.string("t")
  w.string(column)
  w.u16(9)
  w.to_bytes()
}

///|
fn session_row(value : Int32) -> Bytes raise {
  let w = @codec.Writer::new()
  w.i32(2)
  w.i32(4)
  w.i32(1)
  w.i32(1)
  @types.write_value(w, Integer(value))
  w.to_bytes()
}

///|
fn assert_session_prepare(frame : @protocol.MessageEnvelope) -> Unit raise {
  assert_eq(frame.header.opcode, 9)
  let r = @codec.Reader::new(frame.body)
  assert_eq(r.long_string(), "SELECT value FROM t WHERE arg=?")
  assert_eq(r.i32(), 1)
  assert_eq(r.string(), "fixed_keyspace")
  r.finish()
}

///|
fn assert_session_execute(
  frame : @protocol.MessageEnvelope,
  id : Bytes,
  metadata : Bytes,
  value : Int32,
) -> Unit raise {
  assert_eq(frame.header.opcode, 10)
  let r = @codec.Reader::new(frame.body)
  assert_eq(r.short_bytes(), id)
  assert_eq(r.short_bytes(), metadata)
  assert_eq(r.u16(), 10)
  assert_eq(r.i32(), 131)
  assert_eq(r.u16(), 1)
  assert_eq(r.bytes(), Some(@types.encode_scalar(Integer(value))))
  assert_eq(r.string(), "fixed_keyspace")
  r.finish()
}

///|
fn unprepared_error(id : Bytes) -> Bytes raise {
  let w = @codec.Writer::new()
  w.i32(0x2500)
  w.string("missing prepared statement")
  w.short_bytes(id)
  w.to_bytes()
}

///|
async test "same session prepared object survives replacement and preserves keyspace bindings and metadata" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let bindings : Array[@types.Value] = [Integer(7)]
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        {
          let (tcp, _) = server.accept()
          let peer = Peer::new(tcp)
          defer peer.close()
          handshake(peer)
          let prepare = receive(peer)
          assert_session_prepare(prepare)
          respond(
            peer,
            prepare.header.stream,
            8,
            session_metadata(b"old", b"meta-old", "old_column"),
          )
          let execute = receive(peer)
          assert_session_execute(execute, b"old", b"meta-old", 7)
          respond(peer, execute.header.stream, 8, session_row(7))
          assert_eq(receive(peer).header.opcode, 7)
        }
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let prepare = receive(peer)
        assert_session_prepare(prepare)
        bindings[0] = Integer(99)
        respond(
          peer,
          prepare.header.stream,
          8,
          session_metadata(b"new", b"meta-new", "new_column"),
        )
        let execute = receive(peer)
        assert_session_execute(execute, b"new", b"meta-new", 8)
        respond(peer, execute.header.stream, 0, unprepared_error(b"new"))
        let prepare = receive(peer)
        assert_session_prepare(prepare)
        bindings[0] = Integer(100)
        respond(
          peer,
          prepare.header.stream,
          8,
          session_metadata(b"fresh", b"meta-fresh", "fresh_column"),
        )
        let execute = receive(peer)
        assert_session_execute(execute, b"fresh", b"meta-fresh", 8)
        respond(peer, execute.header.stream, 8, session_row(8))
        let execute = receive(peer)
        assert_session_execute(execute, b"fresh", b"meta-fresh", 9)
        respond(peer, execute.header.stream, 8, session_row(9))
        assert_eq(peer.read_some(), None)
      })
      @client.with_session_builder(
        config=@client.SessionBuilder::new(
          connection=@client.ConnectionBuilder::new(port=server.addr.port()),
        ),
        session => {
          let statement = session.prepare(
            "SELECT value FROM t WHERE arg=?",
            keyspace="fixed_keyspace",
          )
          assert_eq(statement.parameters().length(), 1)
          let options = @protocol.QueryOptions::new(skip_metadata=true)
          assert_true(
            try {
              ignore(
                statement.execute(
                  bindings,
                  options=@protocol.QueryOptions::new(keyspace="wrong"),
                ),
              )
              false
            } catch {
              @client.Configuration(_) => true
              _ => false
            },
          )
          guard statement.execute(bindings, options~) is Rows(first) else {
            fail("missing first row")
          }
          assert_eq(first.columns[0].name, "old_column")
          assert_true(
            try {
              ignore(session.query("disconnect"))
              false
            } catch {
              _ => true
            },
          )
          bindings[0] = Integer(8)
          guard statement.execute(bindings, options~) is Rows(second) else {
            fail("missing recovered row")
          }
          assert_eq(second.columns[0].name, "fresh_column")
          assert_eq(second.rows[0][0], @types.Value::Integer(8))
          guard statement.execute([Integer(9)], options~) is Rows(third) else {
            fail("missing reused row")
          }
          assert_eq(third.rows[0][0], @types.Value::Integer(9))
          assert_eq(first.columns[0].name, "old_column")
          assert_eq(session.status().generation, 2)
        },
      )
      worker.wait()
    })
  })
}

///|
async test "session prepared rejects mismatched UNPREPARED and bounds matching recovery to once" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let prepare = receive(peer)
        respond(peer, prepare.header.stream, 8, prepared_result(b"old"))
        let first = receive(peer)
        respond(peer, first.header.stream, 0, unprepared_error(b"unrelated"))
        let second = receive(peer)
        assert_eq(second.header.opcode, 10)
        respond(peer, second.header.stream, 0, unprepared_error(b"old"))
        let prepare = receive(peer)
        assert_eq(prepare.header.opcode, 9)
        respond(peer, prepare.header.stream, 8, prepared_result(b"new"))
        let execute = receive(peer)
        respond(peer, execute.header.stream, 0, unprepared_error(b"new"))
        let last = receive(peer)
        assert_eq(last.header.opcode, 7)
        respond(peer, last.header.stream, 8, b"\x00\x00\x00\x01")
        assert_eq(peer.read_some(), None)
      })
      @client.with_session_builder(
        config=@client.SessionBuilder::new(
          connection=@client.ConnectionBuilder::new(port=server.addr.port()),
        ),
        session => {
          let statement = session.prepare("query")
          for _ in 0..<2 {
            assert_true(
              try {
                ignore(statement.execute([Integer(1)]))
                false
              } catch {
                @client.Server(error) => error.code == 0x2500
                _ => false
              },
            )
          }
          assert_true(session.query("still usable") is Void)
        },
      )
      worker.wait()
    })
  })
}
