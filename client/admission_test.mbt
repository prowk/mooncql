///|
async test "waiting request count and encoded bytes remain bounded under repeated overload" {
  for byte_limit in [false, true] {
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
          let first = receive(peer)
          seen.put(())
          release.get()
          respond(peer, first.header.stream, 8, b"\x00\x00\x00\x01")
          let last = receive(peer)
          assert_eq(@codec.Reader::new(last.body).long_string(), "last")
          respond(peer, last.header.stream, 8, b"\x00\x00\x00\x01")
          assert_eq(peer.read_some(), None)
        })
        let values : Array[@types.Value] = [Bytes(Bytes::make(400000, b'a'))]
        let bytes = @protocol.query("write", values~).body.length() + 9
        @client.with_connection_builder(
          config=@client.ConnectionBuilder::new(
            port=server.addr.port(),
            max_in_flight=if byte_limit { 128 } else { 1 },
            max_in_flight_bytes=bytes,
            max_waiting=if byte_limit { 10 } else { 1 },
            max_waiting_bytes=bytes,
          ),
          connection => {
            @async.with_task_group(requests => {
              let first = requests.spawn(() => {
                connection.query("write", values~)
              })
              seen.get()
              let queued = requests.spawn(() => {
                connection.query("write", values~)
              })
              while connection.waiting_count() == 0 {
                @async.pause()
              }
              for _ in 0..<100 {
                assert_true(
                  try {
                    ignore(connection.query("write", values~))
                    false
                  } catch {
                    @client.Overloaded(reason) =>
                      reason ==
                      (if byte_limit {
                        WaitingBytesFull
                      } else {
                        WaitingQueueFull
                      })
                    _ => false
                  },
                )
              }
              assert_eq(connection.waiting_count(), 1)
              assert_eq(connection.in_flight_count(), 1)
              assert_eq(connection.waiting_bytes(), bytes.to_int64())
              assert_eq(connection.in_flight_bytes(), bytes.to_int64())
              queued.cancel()
              ignore(queued.wait()) catch {
                _ => ()
              }
              assert_eq(connection.waiting_count(), 0)
              assert_eq(connection.waiting_bytes(), 0L)
              release.put(())
              assert_true(first.wait() is Void)
            })
            assert_true(connection.query("last") is Void)
            assert_eq(connection.in_flight_count(), 0)
            assert_eq(connection.in_flight_bytes(), 0L)
          },
        )
        worker.wait()
      })
    })
  }
}

///|
async test "reject policy distinguishes count and byte pressure without sending rejected work" {
  for byte_limit in [false, true] {
    @async.with_timeout(3000, () => {
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
          let request = receive(peer)
          seen.put(())
          release.get()
          respond(peer, request.header.stream, 8, b"\x00\x00\x00\x01")
          assert_eq(peer.read_some(), None)
        })
        let bytes = @protocol.query("write").body.length() + 9
        @client.with_connection_builder(
          config=@client.ConnectionBuilder::new(
            port=server.addr.port(),
            max_in_flight=if byte_limit { 128 } else { 1 },
            max_in_flight_bytes=if byte_limit { bytes } else { 10000 },
            overload_policy=Reject,
          ),
          connection => {
            @async.with_task_group(requests => {
              let first = requests.spawn(() => connection.query("write"))
              seen.get()
              assert_true(
                try {
                  ignore(connection.query("write"))
                  false
                } catch {
                  @client.Overloaded(reason) =>
                    reason ==
                    (if byte_limit { ByteLimit } else { InFlightLimit })
                  _ => false
                },
              )
              assert_eq(connection.waiting_count(), 0)
              release.put(())
              assert_true(first.wait() is Void)
            })
            assert_eq(connection.in_flight_bytes(), 0L)
          },
        )
        worker.wait()
      })
    })
  }
}

///|
async test "single request larger than byte budget fails before any application write" {
  @async.with_task_group(group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let worker = group.spawn(() => {
      let (tcp, _) = server.accept()
      let peer = Peer::new(tcp)
      defer peer.close()
      handshake(peer)
      assert_eq(peer.read_some(), None)
    })
    @client.with_connection_builder(
      config=@client.ConnectionBuilder::new(
        port=server.addr.port(),
        max_in_flight_bytes=32,
      ),
      connection => {
        assert_true(
          try {
            ignore(
              connection.query("large", values=[Bytes(Bytes::make(100, b'x'))]),
            )
            false
          } catch {
            @client.Overloaded(RequestTooLarge) => true
            _ => false
          },
        )
        assert_eq(connection.in_flight_bytes(), 0L)
        assert_eq(connection.waiting_count(), 0)
        assert_true(!connection.is_closed())
      },
    )
    worker.wait()
  })
}

///|
async test "EOF wakes byte waiters and returns all admission budgets" {
  @async.with_timeout(3000, () => {
    @async.with_task_group(group => {
      let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let disconnect : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        ignore(receive(peer))
        seen.put(())
        disconnect.get()
      })
      @client.with_connection_builder(
        config=@client.ConnectionBuilder::new(
          port=server.addr.port(),
          max_in_flight=1,
        ),
        connection => {
          @async.with_task_group(requests => {
            async fn send() {
              try {
                ignore(connection.query("write"))
                false
              } catch {
                _ => true
              }
            }
            let first = requests.spawn(send)
            seen.get()
            let second = requests.spawn(send)
            while connection.waiting_count() != 1 {
              @async.pause()
            }
            disconnect.put(())
            assert_true(first.wait())
            assert_true(second.wait())
          })
          assert_eq(connection.in_flight_count(), 0)
          assert_eq(connection.in_flight_bytes(), 0L)
          assert_eq(connection.waiting_count(), 0)
          assert_eq(connection.waiting_bytes(), 0L)
        },
      )
      worker.wait()
    })
  })
}

///|
async test "THROW_ON_OVERLOAD uses value one and server overload never replays a write" {
  for enabled in [false, true] {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer, throw_on_overload=enabled)
        let first = receive(peer)
        let w = @codec.Writer::new()
        w.i32(0x1001)
        w.string("overloaded")
        respond(peer, first.header.stream, 0, w.to_bytes())
        let second = receive(peer)
        assert_eq(@codec.Reader::new(second.body).long_string(), "next")
        respond(peer, second.header.stream, 8, b"\x00\x00\x00\x01")
        assert_eq(peer.read_some(), None)
      })
      @client.with_connection_builder(
        config=@client.ConnectionBuilder::new(
          port=server.addr.port(),
          throw_on_overload=enabled,
        ),
        connection => {
          assert_true(
            try {
              ignore(connection.query("write once"))
              false
            } catch {
              @client.Server(error) => error.code == 0x1001
              _ => false
            },
          )
          assert_eq(connection.in_flight_bytes(), 0L)
          assert_true(connection.query("next") is Void)
          assert_eq(connection.in_flight_count(), 0)
        },
      )
      worker.wait()
    })
  }
}
