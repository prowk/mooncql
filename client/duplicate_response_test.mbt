///|
async test "coalesced duplicate responses fail after live delivery or abandoned retirement without reusing stream" {
  for cancelled in [false, true] {
    @async.with_timeout(5000, () => {
      @async.with_task_group(group => {
        let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
        defer server.close()
        let barrier = FaultBarrier::new("duplicate response release")
        let worker = group.spawn(() => {
          let (tcp, _) = server.accept()
          let peer = Peer::new(tcp)
          defer peer.close()
          handshake(peer)
          let request = receive(peer)
          barrier.arrive()
          let bytes = @protocol.encode_envelope(
            request.header.stream,
            8,
            b"\x00\x00\x00\x01",
            response=true,
          )
          let w = @codec.Writer::new()
          w.raw(bytes)
          w.raw(bytes)
          peer.write(@framing.encode(w.to_bytes(), self_contained=true))
          assert_eq(peer.read_some(), None)
        })
        @client.with_connection_builder(
          config=@client.ConnectionBuilder::new(port=server.addr.port()),
          connection => {
            @async.with_task_group(requests => {
              let request = requests.spawn(() => connection.query("one"))
              barrier.wait()
              if cancelled {
                request.cancel()
                ignore(request.wait()) catch {
                  _ => ()
                }
                assert_eq(connection.abandoned_count(), 1)
              }
              barrier.release()
              if !cancelled {
                assert_true(request.wait() is Void)
              }
              while !connection.is_closed() {
                @async.pause()
              }
              assert_eq(connection.pending_count(), 0)
              assert_eq(connection.abandoned_count(), 0)
              assert_eq(connection.in_flight_bytes(), 0L)
              assert_true(
                try {
                  ignore(connection.query("must not send"))
                  false
                } catch {
                  @client.Closed => true
                  _ => false
                },
              )
            })
          },
        )
        worker.wait()
      })
    })
  }
}
