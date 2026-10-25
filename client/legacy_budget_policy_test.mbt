///|
async test "disabled Session total budget cannot turn per connection Wait into Reject" {
  @async.with_timeout(4000, () => {
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
        let first = receive(peer)
        seen.put(())
        release.get()
        respond(peer, first.header.stream, 8, b"\x00\x00\x00\x01")
        let second = receive(peer)
        respond(peer, second.header.stream, 8, b"\x00\x00\x00\x01")
        assert_eq(peer.read_some(), None)
      })
      let config = @client.SessionBuilder::new(
        connection=@client.ConnectionBuilder::new(
          port=server.addr.port(),
          max_in_flight=1,
          overload_policy=Wait,
          heartbeat_interval_ms=0,
        ),
        limits=@client.SessionLimits::new(
          max_in_flight=1,
          overload_policy=Reject,
        ),
      )
      @client.with_session_builder(
        config={ ..config, enforce_limits: false, },
        session => {
          @async.with_task_group(requests => {
            let first = requests.spawn(() => session.query("first"))
            seen.get()
            let second = requests.spawn(() => session.query("second"))
            while session.budget().waiting == 0 {
              @async.pause()
            }
            assert_true(session.budget().limits is None)
            release.put(())
            assert_true(first.wait() is Void)
            assert_true(second.wait() is Void)
          })
          session.close()
          assert_eq(session.budget().waiting_bytes, 0L)
          assert_eq(session.resources().background_task_handles, 0)
        },
      )
      worker.wait()
    })
  })
}
