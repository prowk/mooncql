///|
async test "raw cached column metadata freezes nested types before queueing and result ownership is observable" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let held = receive(peer)
        seen.put(())
        release.get()
        respond(peer, held.header.stream, 8, b"\x00\x00\x00\x01")
        let queued = receive(peer)
        let w = @codec.Writer::new()
        w.i32(2)
        w.i32(4)
        w.i32(1)
        w.i32(1)
        @types.write_value(w, TupleValue([Integer(71)]))
        respond(peer, queued.header.stream, 8, w.to_bytes())
        assert_eq(peer.read_some(), None)
      })
      let fields : Array[@types.CqlType] = [Int]
      let cached : Array[@protocol.Column] = [
        { keyspace: "ks", table: "t", name: "value", typ: Tuple(fields), },
      ]
      @client.with_connection_builder(
        config=@client.ConnectionBuilder::new(
          port=server.addr.port(),
          max_in_flight=1,
        ),
        connection => {
          @async.with_task_group(requests => {
            let held = requests.spawn(() => connection.query("held"))
            seen.get()
            let queued = requests.spawn(() => {
              connection.request(@protocol.query("queued"), cached~)
            })
            while connection.waiting_count() != 1 {
              @async.pause()
            }
            fields[0] = Varchar
            cached[0] = {
              keyspace: "elsewhere",
              table: "other",
              name: "changed",
              typ: Blob,
            }
            release.put(())
            assert_true(held.wait() is Void)
            guard queued.wait().response is Result(Rows(page)) else {
              fail("missing page")
            }
            assert_eq(
              page.get(0, "value"),
              @types.Value::TupleValue([Integer(71)]),
            )
            let memory = connection.receive_memory()
            assert_eq(memory.delivering_body_bytes, 0L)
            assert_eq(memory.queued_envelope_bytes, 0L)
            assert_eq(memory.reassembling_bytes, 0L)
            assert_eq(memory.decoded_responses, 2L)
            assert_true(memory.peak_delivering_body_bytes > 0L)
            // 仍由应用持有 page，驱动交付计数已归零。
            assert_eq(page.rows.length(), 1)
          })
        },
      )
      worker.wait()
    })
  })
}
