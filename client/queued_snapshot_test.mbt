///|
async test "queued Session retry freezes nested values payload and contact point collections" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let nested : Array[@types.Value] = [Integer(7)]
      let values : Array[@types.Value] = [ListValue([TupleValue(nested)])]
      let payload : Map[String, Bytes?] = Map([("tag", Some(b"original"))])
      let options = @protocol.QueryOptions::new(
        request_options=@protocol.RequestOptions::new(custom_payload=payload),
      )
      let expected = @protocol.query("target", values~, options~)
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let held = receive(peer)
        seen.put(())
        release.get()
        respond(peer, held.header.stream, 8, b"\x00\x00\x00\x01")
        for attempt in 0..<2 {
          let request = receive(peer)
          assert_eq(request.body, expected.body)
          assert_eq(request.header.flags, expected.flags)
          respond(
            peer,
            request.header.stream,
            if attempt == 0 {
              0
            } else {
              8
            },
            if attempt == 0 {
              overload_error()
            } else {
              b"\x00\x00\x00\x01"
            },
          )
        }
        assert_eq(peer.read_some(), None)
      })
      let points = [@client.Endpoint::new(port=server.addr.port())]
      @client.with_session_builder(
        config=@client.SessionBuilder::new(
          contact_points=points,
          limits=@client.SessionLimits::new(max_in_flight=1),
        ),
        session => {
          points.clear()
          @async.with_task_group(requests => {
            let held = requests.spawn(() => session.query("held"))
            seen.get()
            let queued = requests.spawn(() => {
              session.query(
                "target",
                values~,
                options~,
                idempotent=true,
                retry=@client.RetryPolicy::new(max_attempts=2, delay_ms=0),
              )
            })
            while session.budget().waiting == 0 {
              @async.pause()
            }
            nested[0] = Text("changed")
            values.clear()
            payload["tag"] = Some(b"changed")
            options.request_options.unwrap().custom_payload.clear()
            release.put(())
            assert_true(held.wait() is Void)
            assert_true(queued.wait() is Void)
          })
          assert_eq(session.resources().in_flight, 0)
          assert_eq(session.resources().waiting_bytes, 0L)
        },
      )
      worker.wait()
    })
  })
}
