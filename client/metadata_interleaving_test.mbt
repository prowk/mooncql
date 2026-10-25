///|
async test "commitment old NO_METADATA response decodes with its sent schema while new schema remains cached" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let changed : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let prepare = receive(peer)
        respond(peer, prepare.header.stream, 8, prepared_result(b"id"))
        let old = receive(peer)
        let update = receive(peer)
        let body = @codec.Writer::new()
        body.i32(2)
        body.i32(9)
        body.i32(1)
        body.short_bytes(b"text-schema")
        body.string("ks")
        body.string("t")
        body.string("id")
        body.u16(13)
        body.i32(1)
        @types.write_value(body, Text("new"))
        respond(peer, update.header.stream, 8, body.to_bytes())
        changed.get()
        let current = receive(peer)
        let r = @codec.Reader::new(current.body)
        assert_eq(r.short_bytes(), b"id")
        assert_eq(r.short_bytes(), b"text-schema")
        // 相同长度的 int 和 text 数据交错，若误用新列定义会静默错误解码。
        respond(
          peer,
          old.header.stream,
          8,
          rows_result([1633837924], None, omit_metadata=true),
        )
        let body = @codec.Writer::new()
        body.i32(2)
        body.i32(4)
        body.i32(1)
        body.i32(1)
        @types.write_value(body, Text("abcd"))
        respond(peer, current.header.stream, 8, body.to_bytes())
        assert_eq(peer.read_some(), None)
      })
      @client.with_connection_builder(
        config=@client.ConnectionBuilder::new(port=server.addr.port()),
        connection => {
          let statement = connection.prepare("SELECT id FROM ks.t WHERE id=?")
          @async.with_task_group(requests => {
            let old = requests.spawn(() => {
              statement.execute(
                [Integer(1)],
                options=@protocol.QueryOptions::new(skip_metadata=true),
              )
            })
            while connection.pending_count() != 1 {
              @async.pause()
            }
            guard statement.execute([Integer(2)]) is Rows(update) else {
              fail("expected update")
            }
            assert_eq(update.get(0, "id"), @types.Value::Text("new"))
            changed.put(())
            guard statement.execute(
                [Integer(3)],
                options=@protocol.QueryOptions::new(skip_metadata=true),
              )
              is Rows(current) else {
              fail("expected current")
            }
            assert_eq(current.get(0, "id"), @types.Value::Text("abcd"))
            guard old.wait() is Rows(previous) else { fail("expected old") }
            assert_eq(previous.get(0, "id"), @types.Value::Integer(1633837924))
          })
        },
      )
      worker.wait()
    })
  })
}
