///|
fn status_event(up : Bool) -> Bytes raise {
  let w = @codec.Writer::new()
  w.string("STATUS_CHANGE")
  w.string(if up { "UP" } else { "DOWN" })
  w.u8(4)
  w.raw(b"\x7f\x00\x00\x02")
  w.i32(19042)
  w.to_bytes()
}

///|
async test "REGISTER events and out of order replies use independent bounded delivery" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let register = receive(peer)
        assert_eq(register.header.opcode, 11)
        assert_eq(register.body, b"\x00\x01\x00\x0dSTATUS_CHANGE")
        // REGISTER 的 READY 之前也可以合法收到独立事件。
        respond(peer, -1, 12, status_event(true))
        respond(peer, register.header.stream, 2, b"")
        let first = receive(peer)
        let second = receive(peer)
        respond(peer, -1, 12, status_event(false))
        respond(peer, -1, 12, status_event(true))
        respond(peer, -1, 12, status_event(false))
        respond(
          peer,
          second.header.stream,
          8,
          named_result(@codec.Reader::new(second.body).long_string()),
        )
        respond(
          peer,
          first.header.stream,
          8,
          named_result(@codec.Reader::new(first.body).long_string()),
        )
        assert_eq(peer.read_some(), None)
      })
      @client.with_connection(
        config=@client.Config::new(port=server.addr.port(), event_capacity=2),
        connection => {
          connection.register([StatusChange])
          assert_true(
            connection.next_event()
            is Status(Up, { port: 19042, address: b"\x7f\x00\x00\x02", }),
          )
          @async.with_task_group(requests => {
            let first = requests.spawn(() => connection.query("first"))
            let second = requests.spawn(() => connection.query("second"))
            assert_true(first.wait() is SetKeyspace("first"))
            assert_true(second.wait() is SetKeyspace("second"))
          })
          assert_eq(connection.pending_count(), 0)
          assert_eq(connection.dropped_event_count(), 1L)
          assert_true(connection.next_event() is Status(Down, _))
          assert_true(connection.next_event() is Status(Up, _))
          @async.with_task_group(waiters => {
            let waiter = waiters.spawn(() => {
              try {
                ignore(connection.next_event())
                false
              } catch {
                @client.Closed => true
                _ => false
              }
            })
            @async.pause()
            connection.shutdown()
            assert_true(waiter.wait())
          })
        },
      )
      worker.wait()
    })
  })
}

///|
async test "only valid EVENT on stream minus one can bypass normal response association" {
  for invalid in 0..<4 {
    @async.with_timeout(5000, () => {
      @async.with_task_group(group => {
        let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
        defer server.close()
        let worker = group.spawn(() => {
          let (tcp, _) = server.accept()
          let peer = Peer::new(tcp)
          defer peer.close()
          handshake(peer)
          let request = receive(peer)
          match invalid {
            0 =>
              peer.write(
                @framing.encode(
                  b"\x85\x00\xff\xff\x08\x00\x00\x00\x04\x00\x00\x00\x01",
                ),
              )
            1 => respond(peer, request.header.stream, 12, status_event(true))
            2 => {
              // 绕过合法编码器，注入服务端发来的非法负 stream。
              let body = status_event(true)
              let w = @codec.Writer::new()
              w.raw(b"\x85\x00\xff\xfe\x0c")
              w.i32(body.length())
              w.raw(body)
              peer.write(@framing.encode(w.to_bytes()))
            }
            _ => respond(peer, -1, 12, b"\x00\x03BAD")
          }
          assert_eq(peer.read_some(), None)
        })
        @client.with_connection(
          config=@client.Config::new(port=server.addr.port()),
          connection => {
            assert_true(
              try {
                ignore(connection.query("must fail"))
                false
              } catch {
                @client.Unexpected(_) | @codec.CodecError(_) => true
                _ => false
              },
            )
            assert_true(connection.is_closed())
            assert_eq(connection.pending_count(), 0)
            assert_eq(connection.in_flight_count(), 0)
          },
        )
        worker.wait()
      })
    })
  }
}

///|
async test "event burst cannot block query progress when consumer is stalled" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let register = receive(peer)
        respond(peer, register.header.stream, 2, b"")
        let query = receive(peer)
        for _ in 0..<1000 {
          respond(peer, -1, 12, status_event(true))
        }
        respond(peer, query.header.stream, 8, b"\x00\x00\x00\x01")
        assert_eq(peer.read_some(), None)
      })
      @client.with_connection(
        config=@client.Config::new(port=server.addr.port(), event_capacity=1),
        connection => {
          connection.register([StatusChange])
          assert_true(connection.query("consumer stalled") is Void)
          assert_eq(connection.dropped_event_count(), 999L)
          assert_true(connection.next_event() is Status(Up, _))
          assert_eq(connection.pending_count(), 0)
        },
      )
      worker.wait()
    })
  })
}
