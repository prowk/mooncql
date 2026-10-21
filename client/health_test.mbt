///|
fn heartbeat_supported() -> Bytes raise {
  let w = @codec.Writer::new()
  w.u16(1)
  w.string("CQL_VERSION")
  w.u16(1)
  w.string("3.0.0")
  w.to_bytes()
}

///|
async test "idle heartbeat uses negotiated frames and leaves connection usable" {
  for compressed in [false, true] {
    @async.with_timeout(3000, () => {
      @async.with_task_group(group => {
        let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
        defer server.close()
        let probed : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
        let worker = group.spawn(() => {
          let (tcp, _) = server.accept()
          let peer = Peer::new(tcp, compressed~)
          defer peer.close()
          handshake(peer)
          let heartbeat = receive(peer)
          assert_eq(heartbeat.header.opcode, 5)
          respond(peer, heartbeat.header.stream, 6, heartbeat_supported())
          probed.put(())
          let query = receive(peer)
          assert_eq(query.header.opcode, 7)
          respond(peer, query.header.stream, 8, b"\x00\x00\x00\x01")
          assert_eq(peer.read_some(), None)
        })
        @client.with_connection(
          config=@client.Config::new(
            port=server.addr.port(),
            compression=compressed,
            heartbeat_interval_ms=40,
            heartbeat_timeout_ms=200,
          ),
          connection => {
            probed.get()
            assert_true(connection.query("after heartbeat") is Void)
            connection.shutdown()
            assert_eq(connection.pending_count(), 0)
            assert_eq(connection.in_flight_bytes(), 0L)
          },
        )
        worker.wait()
      })
    })
  }
}

///|
async test "heartbeat timeout replaces half open connection before next business request" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        {
          let (tcp, _) = server.accept()
          let peer = Peer::new(tcp)
          defer peer.close()
          handshake(peer)
          assert_eq(receive(peer).header.opcode, 5)
          // 保持 TCP 打开但不返回心跳，模拟空闲连接半断开。
          assert_eq(peer.read_some(), None)
        }
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        while true {
          let request = receive(peer)
          if request.header.opcode == 5 {
            respond(peer, request.header.stream, 6, heartbeat_supported())
          } else {
            assert_eq(request.header.opcode, 7)
            respond(peer, request.header.stream, 8, b"\x00\x00\x00\x01")
            break
          }
        }
        assert_eq(peer.read_some(), None)
      })
      @client.with_session(
        config=@client.SessionConfig::new(
          connection=@client.Config::new(
            port=server.addr.port(),
            heartbeat_interval_ms=40,
            heartbeat_timeout_ms=50,
          ),
          backoff_initial_ms=5,
          backoff_max_ms=20,
          jitter=0.0,
        ),
        session => {
          while session.status().generation < 2 {
            @async.sleep(5)
          }
          assert_true(session.query("recovered") is Void)
          session.close()
          assert_eq(session.resources().background_task_handles, 0)
          assert_eq(session.resources().pending, 0)
          assert_eq(session.resources().in_flight_bytes, 0L)
        },
      )
      worker.wait()
    })
  })
}

///|
async test "heartbeat does not interrupt active requests and can be disabled" {
  for disabled in [false, true] {
    @async.with_timeout(3000, () => {
      @async.with_task_group(group => {
        let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
        defer server.close()
        let worker = group.spawn(() => {
          let (tcp, _) = server.accept()
          let peer = Peer::new(tcp)
          defer peer.close()
          handshake(peer)
          let request = receive(peer)
          assert_eq(request.header.opcode, 7)
          // 业务响应晚于心跳间隔及心跳超时，仍遵守业务请求自己的期限。
          assert_true(@async.with_timeout_opt(120, () => receive(peer)) is None)
          respond(peer, request.header.stream, 8, b"\x00\x00\x00\x01")
          assert_eq(peer.read_some(), None)
        })
        @client.with_connection(
          config=@client.Config::new(
            port=server.addr.port(),
            heartbeat_interval_ms=if disabled { 0 } else { 20 },
            heartbeat_timeout_ms=30,
          ),
          connection => {
            if disabled {
              @async.sleep(80)
            }
            assert_true(connection.query("slow business request") is Void)
            assert_true(!connection.is_closed())
          },
        )
        worker.wait()
      })
    })
  }
}

///|
async test "closing Session cancels and joins an in flight heartbeat" {
  @async.with_timeout(3000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        assert_eq(receive(peer).header.opcode, 5)
        seen.put(())
        assert_eq(peer.read_some(), None)
      })
      @client.with_session(
        config=@client.SessionConfig::new(
          connection=@client.Config::new(
            port=server.addr.port(),
            heartbeat_interval_ms=20,
            heartbeat_timeout_ms=10000,
          ),
        ),
        session => {
          seen.get()
          session.close()
          let resources = session.resources()
          assert_eq(resources.background_task_handles, 0)
          assert_eq(resources.pending, 0)
          assert_eq(resources.abandoned, 0)
          assert_eq(resources.in_flight_bytes, 0L)
        },
      )
      worker.wait()
    })
  })
}
