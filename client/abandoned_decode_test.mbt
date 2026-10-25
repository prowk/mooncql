///|
async test "abandoned body skips semantic decode while CRC direction stream and opcode remain enforced" {
  for fault in 0..<5 {
    for compressed in [false, true] {
      @async.with_timeout(5000, () => {
        @async.with_task_group(group => {
          let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
          defer server.close()
          let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
          let release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
          let worker = group.spawn(() => {
            let (tcp, _) = server.accept()
            let peer = Peer::new(tcp, compressed~)
            defer peer.close()
            handshake(peer)
            let abandoned = receive(peer)
            seen.put(())
            release.get()
            // 正文故意不是合法 ROWS，验证不会构造或校验废弃的结果对象。
            let envelope = @protocol.encode_envelope(
              if fault == 3 {
                (abandoned.header.stream + 1) % 32768
              } else {
                abandoned.header.stream
              },
              if fault == 4 {
                255
              } else {
                8
              },
              Bytes::make(400000, b'x'),
              response=fault != 2,
            )
            let frames = @framing.split(envelope, compressed~)
            if fault == 1 {
              let broken = frames[0].to_array()
              let last = broken.length() - 1
              broken[last] = (broken[last].to_int() ^ 1).to_byte()
              frames[0] = Bytes::from_array(broken)
            }
            try {
              for frame in frames {
                peer.write(frame)
              }
            } catch {
              error => if fault == 0 { raise error }
            }
            if fault == 0 {
              let next = receive(peer)
              respond(peer, next.header.stream, 8, b"\x00\x00\x00\x01")
              assert_eq(peer.read_some(), None)
            }
          })
          @client.with_connection_builder(
            config=@client.ConnectionBuilder::new(
              port=server.addr.port(),
              compression=compressed,
              heartbeat_interval_ms=0,
            ),
            connection => {
              @async.with_task_group(requests => {
                let task = requests.spawn(() => connection.query("abandoned"))
                seen.get()
                task.cancel()
                ignore(task.wait()) catch {
                  _ => ()
                }
                assert_eq(connection.pending_count(), 1)
                assert_eq(connection.abandoned_count(), 1)
                release.put(())
                while connection.pending_count() != 0 {
                  @async.pause()
                }
                assert_eq(connection.in_flight_bytes(), 0L)
                assert_eq(connection.abandoned_count(), 0)
                if fault == 0 {
                  assert_true(!connection.is_closed())
                  assert_true(connection.query("after drain") is Void)
                } else {
                  assert_true(connection.is_closed())
                }
              })
            },
          )
          worker.wait()
        })
      })
    }
  }
}
