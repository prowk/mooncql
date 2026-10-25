///|
async test "in-flight limit applies backpressure before a second request is sent" {
  @async.with_timeout(3000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let socket = Peer::new(tcp)
        defer socket.close()
        handshake(socket)
        let first = receive(socket)
        assert_true(@async.with_timeout_opt(50, () => receive(socket)) is None)
        respond(socket, first.header.stream, 8, b"\x00\x00\x00\x01")
        let second = receive(socket)
        respond(socket, second.header.stream, 8, b"\x00\x00\x00\x01")
      })
      @client.with_connection_builder(
        config=@client.ConnectionBuilder::new(
          port=server.addr.port(),
          max_in_flight=1,
        ),
        connection => {
          let results = @async.all([
            () => connection.query("one"),
            () => connection.query("two"),
          ])
          assert_true(results[0] is Void)
          assert_true(results[1] is Void)
        },
      )
      worker.wait()
    })
  })
}

///|
async test "sent cancellation reserves its stream and absorbs a late response" {
  @async.with_timeout(3000, () => {
    @async.with_task_group(group => {
      let sent : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let socket = Peer::new(tcp)
        defer socket.close()
        handshake(socket)
        let abandoned = receive(socket)
        sent.put(())
        let current = receive(socket)
        assert_true(current.header.stream != abandoned.header.stream)
        respond(socket, current.header.stream, 8, named_result("current"))
        respond(socket, abandoned.header.stream, 8, named_result("late"))
        let last = receive(socket)
        respond(socket, last.header.stream, 8, named_result("last"))
        assert_eq(socket.read_some(), None)
      })
      @client.with_connection_builder(
        config=@client.ConnectionBuilder::new(port=server.addr.port()),
        connection => {
          @async.with_task_group(requests => {
            let task = requests.spawn(() => connection.query("write"))
            sent.get()
            task.cancel()
            ignore(task.wait()) catch {
              _ => ()
            }
          })
          assert_true(!connection.is_closed())
          assert_eq(connection.pending_count(), 1)
          assert_eq(connection.abandoned_count(), 1)
          assert_true(connection.query("current") is SetKeyspace("current"))
          assert_true(connection.query("last") is SetKeyspace("last"))
          assert_eq(connection.pending_count(), 0)
          assert_eq(connection.abandoned_count(), 0)
        },
      )
      worker.wait()
    })
  })
}

///|
async test "invalid stream truncated frame and oversize frame fail waiting requests" {
  for
    malformed in [
      b"\x85\x00\x7f\xff\x08\x00\x00\x00\x04\x00\x00\x00\x01", b"\x85\x00", b"\x85\x00\x00\x00\x08\x7f\xff\xff\xff",
    ] {
    @async.with_timeout(3000, () => {
      @async.with_task_group(group => {
        let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
        defer server.close()
        let worker = group.spawn(() => {
          let (tcp, _) = server.accept()
          let socket = Peer::new(tcp)
          defer socket.close()
          handshake(socket)
          ignore(receive(socket))
          socket.write(@framing.encode(malformed))
        })
        @client.with_connection_builder(
          config=@client.ConnectionBuilder::new(port=server.addr.port()),
          connection => {
            assert_true(
              try {
                ignore(connection.query("query"))
                false
              } catch {
                _ => true
              },
            )
            assert_true(connection.is_closed())
          },
        )
        worker.wait()
      })
    })
  }
}

///|
async test "UNPREPARED recovery is bounded and leaves connection usable" {
  @async.with_task_group(group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let worker = group.spawn(() => {
      let (tcp, _) = server.accept()
      let socket = Peer::new(tcp)
      defer socket.close()
      handshake(socket)
      for i = 0; i < 2; i = i + 1 {
        let prepare = receive(socket)
        assert_eq(prepare.header.opcode, 9)
        respond(socket, prepare.header.stream, 8, prepared_result(b"id"))
        let execute = receive(socket)
        assert_eq(execute.header.opcode, 10)
        let w = @codec.Writer::new()
        w.i32(0x2500)
        w.string("missing")
        w.short_bytes(b"id")
        respond(socket, execute.header.stream, 0, w.to_bytes())
      }
      let query = receive(socket)
      assert_eq(query.header.opcode, 7)
      respond(socket, query.header.stream, 8, b"\x00\x00\x00\x01")
    })
    @client.with_connection_builder(
      config=@client.ConnectionBuilder::new(port=server.addr.port()),
      connection => {
        let prepared = connection.prepare("query")
        assert_true(
          try {
            ignore(prepared.execute([Integer(1)]))
            false
          } catch {
            @client.Server(error) => error.code == 0x2500
            _ => false
          },
        )
        assert_true(connection.query("still usable") is Void)
      },
    )
    worker.wait()
  })
}

///|
async test "missing credentials close the handshake without sending an auth token" {
  @async.with_task_group(group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let worker = group.spawn(() => {
      let (tcp, _) = server.accept()
      let socket = Peer::new(tcp)
      defer socket.close()
      let options = receive(socket)
      let w = @codec.Writer::new()
      w.u16(1)
      w.string("CQL_VERSION")
      w.u16(1)
      w.string("3.0.0")
      respond(socket, options.header.stream, 6, w.to_bytes())
      let startup = receive(socket)
      let w = @codec.Writer::new()
      w.string("org.apache.cassandra.auth.PasswordAuthenticator")
      respond(socket, startup.header.stream, 3, w.to_bytes())
      assert_eq(socket.read_some(), None)
    })
    assert_true(
      try {
        let connection = @client.connect_builder(
          group,
          config=@client.ConnectionBuilder::new(port=server.addr.port()),
        )
        connection.close()
        false
      } catch {
        @client.Authentication(_) => true
        _ => false
      },
    )
    worker.wait()
  })
}
