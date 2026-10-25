///|
fn nested_parameter_metadata() -> Bytes raise {
  let w = @codec.Writer::new()
  w.i32(4)
  w.short_bytes(b"nested")
  w.short_bytes(b"metadata")
  w.i32(1)
  w.i32(2)
  w.i32(0)
  w.string("ks")
  w.string("t")
  w.string("tuple_arg")
  w.u16(49)
  w.u16(1)
  w.u16(9)
  w.string("udt_arg")
  w.u16(48)
  w.string("ks")
  w.string("thing")
  w.u16(1)
  w.string("field")
  w.u16(32)
  w.u16(49)
  w.u16(1)
  w.u16(9)
  w.i32(0)
  w.i32(0)
  w.to_bytes()
}

///|
fn change_parameter_snapshot(columns : Array[@protocol.Column]) -> Unit raise {
  guard columns[0].typ is Tuple(fields) else { fail("expected tuple") }
  fields[0] = Varchar
  guard columns[1].typ is Udt(_, _, fields) &&
    fields[0].1 is List(Tuple(nested)) else {
    fail("expected nested UDT")
  }
  nested[0] = Varchar
  fields.clear()
  columns.clear()
}

///|
async test "Connection and Session prepared parameter snapshots isolate nested type arrays" {
  for session_level in [false, true] {
    @async.with_timeout(3000, () => {
      @async.with_task_group(group => {
        let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
        defer server.close()
        let worker = group.spawn(() => {
          let (tcp, _) = server.accept()
          let peer = Peer::new(tcp)
          defer peer.close()
          handshake(peer)
          let prepare = receive(peer)
          respond(peer, prepare.header.stream, 8, nested_parameter_metadata())
          let execute = receive(peer)
          assert_eq(execute.header.opcode, 10)
          respond(peer, execute.header.stream, 8, b"\x00\x00\x00\x01")
          assert_eq(peer.read_some(), None)
        })
        let config = @client.ConnectionBuilder::new(port=server.addr.port())
        let values : Array[@types.Value] = [
          TupleValue([Integer(7)]),
          UdtValue([("field", ListValue([TupleValue([Integer(9)])]))]),
        ]
        if session_level {
          @client.with_session_builder(
            config=@client.SessionBuilder::new(connection=config),
            session => {
              let statement = session.prepare(
                "INSERT INTO ks.t (a,b) VALUES (?,?)",
              )
              change_parameter_snapshot(statement.parameters())
              assert_true(statement.execute(values) is Void)
            },
          )
        } else {
          @client.with_connection_builder(config~, connection => {
            let statement = connection.prepare(
              "INSERT INTO ks.t (a,b) VALUES (?,?)",
            )
            change_parameter_snapshot(statement.parameters())
            assert_true(statement.execute(values) is Void)
          })
        }
        worker.wait()
      })
    })
  }
}
