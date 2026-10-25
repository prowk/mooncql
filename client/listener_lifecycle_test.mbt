///|
priv suberror LifecycleListenerFailure

///|
async test "legacy and diagnostic listeners may fail or close a connection without duplicate completion or late callbacks" {
  for close_on_start in [false, true] {
    @async.with_timeout(4000, () => {
      @async.with_task_group(group => {
        let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
        defer server.close()
        let connections : Array[@client.Connection] = []
        let completions = [0]
        let callbacks = [0]
        let metrics = @client.Metrics::with_diagnostics(
          _ => {
            callbacks[0] += 1
            raise LifecycleListenerFailure
          },
          listener=event => {
            callbacks[0] += 1
            match event {
              RequestStarted(_, _, _) =>
                if close_on_start {
                  connections[0].close()
                }
              RequestFinished(_) => {
                completions[0] += 1
                if !close_on_start {
                  connections[0].close()
                }
              }
              _ => ()
            }
            raise LifecycleListenerFailure
          },
        )
        let worker = group.spawn(() => {
          let (tcp, _) = server.accept()
          let peer = Peer::new(tcp)
          defer peer.close()
          handshake(peer)
          if !close_on_start {
            let request = receive(peer)
            respond(peer, request.header.stream, 8, b"\x00\x00\x00\x01")
          }
          assert_eq(peer.read_some(), None)
        })
        @client.with_connection_builder(
          config=@client.ConnectionBuilder::new(
            port=server.addr.port(),
            metrics~,
          ),
          connection => {
            connections.push(connection)
            let outcome = Some(connection.query("one")) catch {
              @client.Closed => None
              error => raise error
            }
            if close_on_start {
              assert_true(outcome is None)
            } else {
              assert_true(outcome is Some(Void))
            }
            connection.shutdown()
            assert_eq(completions[0], 1)
            assert_eq(connection.pending_count(), 0)
            assert_eq(connection.waiting_count(), 0)
            assert_eq(connection.in_flight_bytes(), 0L)
            assert_eq(metrics.snapshot().requests_started, 1L)
            assert_true(metrics.snapshot().listener_errors > 0L)
          },
        )
        worker.wait()
        let stopped = callbacks[0]
        for _ in 0..<4 {
          @async.pause()
        }
        assert_eq(callbacks[0], stopped)
      })
    })
  }
}
