///|
async test "Session resources expose pending abandoned cache and joined task handles" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let prepare = receive(peer)
        assert_eq(prepare.header.opcode, 9)
        respond(peer, prepare.header.stream, 8, prepared_result(b"id"))
        let execute = receive(peer)
        assert_eq(execute.header.opcode, 10)
        seen.put(())
        release.get()
        respond(peer, execute.header.stream, 8, rows_result([7], None))
        let last = receive(peer)
        assert_eq(last.header.opcode, 7)
        respond(peer, last.header.stream, 8, rows_result([9], None))
        assert_eq(peer.read_some(), None)
      })
      @client.with_session(
        config=@client.SessionConfig::new(
          connection=@client.Config::new(
            port=server.addr.port(),
            prepared_cache_capacity=1,
          ),
        ),
        session => {
          let statement = session.prepare("SELECT id FROM ks.t WHERE id=?")
          let before = session.resources()
          assert_eq(before.active, 0)
          assert_eq(before.pending, 0)
          assert_eq(before.cache_sizes, [1])
          assert_eq(before.background_task_handles, 3)
          before.cache_sizes[0] = 100
          assert_eq(session.resources().cache_sizes, [1])
          @async.with_task_group(requests => {
            let task = requests.spawn(() => statement.execute([Integer(7)]))
            seen.get()
            @async.sleep(5)
            let sent = session.resources()
            assert_eq(sent.active, 1)
            assert_eq(sent.pending, 1)
            assert_eq(sent.in_flight, 1)
            assert_true(sent.in_flight_bytes > 0L)
            task.cancel()
            ignore(task.wait()) catch {
              _ => ()
            }
            let cancelled = session.resources()
            assert_eq(cancelled.active, 0)
            assert_eq(cancelled.pending, 1)
            assert_eq(cancelled.abandoned, 1)
            assert_eq(cancelled.in_flight, 1)
            release.put(())
            guard session.query("last") is Rows(page) else {
              fail("missing last row")
            }
            assert_eq(page.row(0).int("id"), 9)
            let drained = session.resources()
            assert_eq(drained.pending, 0)
            assert_eq(drained.abandoned, 0)
            assert_eq(drained.in_flight, 0)
            assert_eq(drained.in_flight_bytes, 0L)
            assert_eq(drained.waiting, 0)
            assert_eq(drained.waiting_bytes, 0L)
          })
          session.close()
          let closed = session.resources()
          assert_eq(closed.active, 0)
          assert_eq(closed.pending, 0)
          assert_eq(closed.background_task_handles, 0)
          assert_eq(closed.cache_sizes, [])
        },
      )
      worker.wait()
    })
  })
}
