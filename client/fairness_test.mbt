///|
async test "Connection and Session send oldest large query before continuous small arrivals" {
  for session_mode in [false, true] {
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
          let held = receive(peer)
          seen.put(())
          release.get()
          respond(peer, held.header.stream, 8, b"\x00\x00\x00\x01")
          let large = receive(peer)
          assert_eq(@codec.Reader::new(large.body).long_string(), "large")
          respond(peer, large.header.stream, 8, b"\x00\x00\x00\x01")
          for index in 0..<24 {
            let next = receive(peer)
            assert_eq(
              @codec.Reader::new(next.body).long_string(),
              "small-\{index}",
            )
            respond(peer, next.header.stream, 8, b"\x00\x00\x00\x01")
          }
          assert_eq(peer.read_some(), None)
        })
        let values : Array[@types.Value] = [Bytes(Bytes::make(1000, b'x'))]
        let max_bytes = @protocol.query("large", values~).body.length() + 9
        let config = @client.ConnectionBuilder::new(
          port=server.addr.port(),
          max_in_flight=64,
          max_in_flight_bytes=max_bytes,
          heartbeat_interval_ms=0,
        )
        async fn exercise(
          query : async (String, Array[@types.Value]) -> @protocol.ResultSet,
          waiting : () -> Int32,
        ) -> Unit {
          @async.with_task_group(requests => {
            let held = requests.spawn(() => query("held", []))
            seen.get()
            let large = requests.spawn(() => query("large", values))
            while waiting() < 1 {
              @async.pause()
            }
            let smalls = []
            for index in 0..<24 {
              smalls.push(requests.spawn(() => query("small-\{index}", [])))
              while waiting() < index + 2 {
                @async.pause()
              }
            }
            release.put(())
            assert_true(held.wait() is Void)
            assert_true(large.wait() is Void)
            for small in smalls {
              assert_true(small.wait() is Void)
            }
          })
          assert_eq(waiting(), 0)
        }
        if session_mode {
          @client.with_session_builder(
            config=@client.SessionBuilder::new(
              connection=config,
              limits=@client.SessionLimits::new(
                max_in_flight=64,
                max_in_flight_bytes=max_bytes,
              ),
            ),
            session => {
              exercise((cql, values) => session.query(cql, values~), () => {
                session.budget().waiting
              })
              assert_eq(session.budget().in_flight, 0)
              assert_eq(session.scheduling().queued, 0)
            },
          )
        } else {
          @client.with_connection_builder(config~, connection => {
            exercise((cql, values) => connection.query(cql, values~), () => {
              connection.waiting_count()
            })
            assert_eq(connection.in_flight_bytes(), 0L)
            assert_eq(connection.scheduling().queued, 0)
          })
        }
        worker.wait()
      })
    })
  }
}
