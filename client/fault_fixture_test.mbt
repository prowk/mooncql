///|
async test "reusable protocol barriers coordinate handshake authentication write split response and half frame EOF" {
  for eof in [false, true] {
    @async.with_timeout(6000, () => {
      @async.with_task_group(group => {
        let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
        defer server.close()
        let options = FaultBarrier::new("OPTIONS")
        let startup = FaultBarrier::new("STARTUP")
        let auth = FaultBarrier::new("AUTH_RESPONSE")
        let write = FaultBarrier::new("application write received")
        let response = FaultBarrier::new("first response byte")
        let closed = FaultBarrier::new("server close")
        let finished = [false]
        let connections : Array[@client.Connection] = []
        let worker = group.spawn(() => {
          let (tcp, _) = server.accept()
          let peer = Peer::new(tcp)
          defer peer.close()
          handshake(
            peer,
            auth=true,
            options_barrier=options,
            startup_barrier=startup,
            auth_barrier=auth,
          )
          let request = receive(peer)
          write.arrive()
          let bytes = @framing.split(
              @protocol.encode_envelope(
                request.header.stream,
                8,
                b"\x00\x00\x00\x01",
                response=true,
              ),
            )[0]
          peer.write_chunks(
            if eof {
              bytes[:3].to_owned()
            } else {
              bytes
            },
            1,
            after_first=response,
          )
          closed.arrive()
          if !eof {
            assert_eq(peer.read_some(), None)
          }
        })
        let caller = group.spawn(() => {
          @client.with_connection(
            config=@client.Config::new(
              port=server.addr.port(),
              username="user",
              password="secret",
              heartbeat_interval_ms=0,
            ),
            connection => {
              connections.push(connection)
              let outcome = Some(connection.query("once")) catch { _ => None }
              finished[0] = true
              if eof {
                assert_true(outcome is None)
              } else {
                assert_true(outcome is Some(Void))
              }
            },
          )
        })
        for barrier in [options, startup, auth, write, response] {
          barrier.wait()
          assert_true(!finished[0], msg="stage \{barrier.phase}")
          if barrier.phase == "first response byte" {
            assert_eq(connections[0].pending_count(), 1)
          }
          barrier.release()
        }
        closed.wait()
        closed.release()
        caller.wait()
        worker.wait()
        assert_eq(connections[0].pending_count(), 0)
        assert_eq(connections[0].in_flight_bytes(), 0L)
      })
    })
  }
}
