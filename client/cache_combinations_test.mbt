///|
async test "capacity one cache combines cancellation singleflight failure eviction UNPREPARED and keyspaces" {
  @async.with_timeout(6000, () => {
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
        let failed = receive(peer)
        seen.put(())
        release.get()
        let error = @codec.Writer::new()
        error.i32(0x2000)
        error.string("invalid")
        respond(peer, failed.header.stream, 0, error.to_bytes())
        for (keyspace, id) in [("a", b"a-old"), ("b", b"b")] {
          let request = receive(peer)
          assert_eq(request.header.opcode, 9)
          let r = @codec.Reader::new(request.body)
          assert_eq(r.long_string(), "same")
          assert_eq(r.i32(), 1)
          assert_eq(r.string(), keyspace)
          r.finish()
          respond(peer, request.header.stream, 8, prepared_result(id))
        }
        let execute = receive(peer)
        assert_eq(@codec.Reader::new(execute.body).short_bytes(), b"a-old")
        respond(peer, execute.header.stream, 0, unprepared_error(b"a-old"))
        let refresh = receive(peer)
        assert_eq(refresh.header.opcode, 9)
        respond(peer, refresh.header.stream, 8, prepared_result(b"a-new"))
        let retried = receive(peer)
        assert_eq(@codec.Reader::new(retried.body).short_bytes(), b"a-new")
        respond(peer, retried.header.stream, 8, rows_result([7], None))
        let b = receive(peer)
        assert_eq(@codec.Reader::new(b.body).short_bytes(), b"b")
        respond(peer, b.header.stream, 8, rows_result([8], None))
        assert_eq(peer.read_some(), None)
      })
      @client.with_connection_builder(
        config=@client.ConnectionBuilder::new(
          port=server.addr.port(),
          prepared_cache_capacity=1,
        ),
        connection => {
          @async.with_task_group(requests => {
            async fn failing() -> Bool {
              try {
                ignore(connection.prepare("same", keyspace="a"))
                false
              } catch {
                @client.Server(error) => error.code == 0x2000
                _ => false
              }
            }
            let owner = requests.spawn(failing)
            seen.get()
            let cancelled = requests.spawn(failing)
            let follower = requests.spawn(failing)
            while connection.waiting_count() != 2 {
              @async.pause()
            }
            cancelled.cancel()
            ignore(cancelled.wait()) catch {
              _ => ()
            }
            release.put(())
            assert_true(owner.wait())
            assert_true(follower.wait())
          })
          assert_eq(connection.waiting_count(), 0)
          assert_eq(connection.prepared_cache_size(), 0)
          let a = connection.prepare("same", keyspace="a")
          let b = connection.prepare("same", keyspace="b")
          assert_eq(connection.prepared_cache_size(), 1)
          guard a.execute([Integer(7)]) is Rows(page) else { fail("missing a") }
          assert_eq(page.row(0).int("id"), 7)
          guard b.execute([Integer(8)]) is Rows(page) else { fail("missing b") }
          assert_eq(page.row(0).int("id"), 8)
          assert_eq(connection.in_flight_count(), 0)
          assert_eq(connection.waiting_bytes(), 0L)
        },
      )
      worker.wait()
    })
  })
}
