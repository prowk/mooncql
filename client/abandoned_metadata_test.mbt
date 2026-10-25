///|
async test "cancelled old metadata response cannot overwrite a newer prepared schema" {
  for compressed in [false, true] {
    @async.with_timeout(5000, () => {
      @async.with_task_group(group => {
        let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
        defer server.close()
        let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
        let release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
        let worker = group.spawn(() => {
          let (tcp, _) = server.accept()
          let peer = Peer::new(tcp, compressed~)
          defer peer.close()
          handshake(peer)
          let prepare = receive(peer)
          respond(peer, prepare.header.stream, 8, prepared_result(b"id"))
          let old = receive(peer)
          seen.put(())
          let update = receive(peer)
          let w = @codec.Writer::new()
          w.i32(2)
          w.i32(9)
          w.i32(1)
          w.short_bytes(b"new-schema")
          w.string("ks")
          w.string("t")
          w.string("id")
          w.u16(13)
          w.i32(1)
          @types.write_value(w, Text("updated"))
          respond(peer, update.header.stream, 8, w.to_bytes())
          release.get()
          // 废弃响应携带旧元数据与大正文，排空后不能回写缓存。
          let late = @codec.Writer::new()
          late.i32(2)
          late.i32(9)
          late.i32(1)
          late.short_bytes(b"stale-schema")
          late.string("ks")
          late.string("t")
          late.string("id")
          late.u16(3)
          late.i32(1)
          @types.write_value(late, Bytes(Bytes::make(400000, b'x')))
          respond(peer, old.header.stream, 8, late.to_bytes())
          let current = receive(peer)
          let r = @codec.Reader::new(current.body)
          assert_eq(r.short_bytes(), b"id")
          assert_eq(r.short_bytes(), b"new-schema")
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
          config=@client.ConnectionBuilder::new(
            port=server.addr.port(),
            compression=compressed,
          ),
          connection => {
            let statement = connection.prepare("SELECT id FROM ks.t WHERE id=?")
            @async.with_task_group(requests => {
              let old = requests.spawn(() => statement.execute([Integer(1)]))
              seen.get()
              guard statement.execute([Integer(2)]) is Rows(page) else {
                fail("update missing")
              }
              assert_eq(page.get(0, "id"), @types.Value::Text("updated"))
              old.cancel()
              ignore(old.wait()) catch {
                _ => ()
              }
              assert_eq(connection.abandoned_count(), 1)
              release.put(())
              while connection.pending_count() > 0 {
                @async.pause()
              }
              guard statement.execute(
                  [Integer(3)],
                  options=@protocol.QueryOptions::new(skip_metadata=true),
                )
                is Rows(current) else {
                fail("current missing")
              }
              assert_eq(current.get(0, "id"), @types.Value::Text("abcd"))
              assert_eq(connection.receive_memory().discarded_responses, 1L)
              assert_eq(connection.in_flight_bytes(), 0L)
            })
          },
        )
        worker.wait()
      })
    })
  }
}
