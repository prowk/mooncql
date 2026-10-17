///|
async test "connection deadline includes OPTIONS and closes a stalled handshake" {
  @async.with_timeout(3000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        assert_eq(receive(peer).header.opcode, 5)
        assert_eq(peer.read_some(), None)
      })
      assert_true(
        try {
          let connection = @client.connect(
            group,
            config=@client.Config::new(
              port=server.addr.port(),
              connect_timeout_ms=50,
            ),
          )
          connection.close()
          false
        } catch {
          @client.TimedOut(info) =>
            info.scope == Connection &&
            info.phase == Connecting &&
            !info.may_have_been_sent
          _ => false
        },
      )
      worker.wait()
    })
  })
}

///|
async test "serial and multiplex requests share queue and execution timing boundaries" {
  for serial in [true, false] {
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
          let first = receive(peer)
          seen.put(())
          release.get()
          respond(peer, first.header.stream, 8, named_result("first"))
          let last = receive(peer)
          assert_eq(@codec.Reader::new(last.body).long_string(), "last")
          seen.put(())
          release.get()
          respond(peer, last.header.stream, 8, named_result("late"))
          assert_eq(peer.read_some(), None)
        })
        async fn check(connection : @client.Connection) {
          @async.with_task_group(requests => {
            let first = requests.spawn(() => connection.query("first"))
            seen.get()
            assert_true(
              try {
                ignore(connection.query("never sent"))
                false
              } catch {
                @client.TimedOut(info) =>
                  info.scope == Queue &&
                  info.phase == WaitingSlot &&
                  !info.may_have_been_sent
                _ => false
              },
            )
            assert_true(!connection.is_closed())
            assert_eq(connection.abandoned_count(), 0)
            release.put(())
            assert_true(first.wait() is SetKeyspace("first"))
          })
          assert_true(
            try {
              ignore(connection.query("last"))
              false
            } catch {
              @client.TimedOut(info) =>
                info.scope == Execution &&
                info.phase == WaitingResponse &&
                info.may_have_been_sent
              _ => false
            },
          )
          seen.get()
          assert_eq(connection.abandoned_count(), 1)
          release.put(())
          while connection.abandoned_count() != 0 {
            @async.pause()
          }
        }
        let config = @client.Config::new(
          port=server.addr.port(),
          max_in_flight=1,
          queue_timeout_ms=40,
          timeout_ms=150,
          operation_timeout_ms=1000,
        )
        if serial {
          @client.with_serial_connection(config~, check)
        } else {
          @client.with_connection(config~, check)
        }
        worker.wait()
      })
    })
  }
}

///|
async test "UNPREPARED reprepare uses the original operation deadline" {
  @async.with_timeout(3000, () => {
    @async.with_task_group(group => {
      let release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let prepare = receive(peer)
        respond(peer, prepare.header.stream, 8, prepared_result(b"id"))
        let execute = receive(peer)
        assert_eq(execute.header.opcode, 10)
        @async.sleep(400)
        let w = @codec.Writer::new()
        w.i32(0x2500)
        w.string("missing")
        w.short_bytes(b"id")
        respond(peer, execute.header.stream, 0, w.to_bytes())
        let prepare = receive(peer)
        assert_eq(prepare.header.opcode, 9)
        release.get()
        respond(peer, prepare.header.stream, 8, prepared_result(b"new"))
        let query = receive(peer)
        assert_eq(query.header.opcode, 7)
        respond(peer, query.header.stream, 8, named_result("still usable"))
        assert_eq(peer.read_some(), None)
      })
      @client.with_connection(
        config=@client.Config::new(
          port=server.addr.port(),
          timeout_ms=2000,
          operation_timeout_ms=2000,
        ),
        connection => {
          let statement = connection.prepare("query")
          let started = @async.now()
          assert_true(
            try {
              ignore(
                statement.execute(
                  [Integer(1)],
                  deadline=@client.Deadline::after(600),
                ),
              )
              false
            } catch {
              @client.TimedOut(info) =>
                info.scope == Operation &&
                info.phase == WaitingResponse &&
                info.may_have_been_sent
              _ => false
            },
          )
          assert_true(@async.now() - started < 900L)
          assert_eq(connection.abandoned_count(), 1)
          release.put(())
          assert_true(
            connection.query("still usable") is SetKeyspace("still usable"),
          )
          assert_eq(connection.pending_count(), 0)
        },
      )
      worker.wait()
    })
  })
}

///|
async test "prepare lock and already expired deadline never send a request" {
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
        let prepare = receive(peer)
        seen.put(())
        release.get()
        respond(peer, prepare.header.stream, 8, prepared_result(b"id"))
        assert_eq(peer.read_some(), None)
      })
      @client.with_connection(
        config=@client.Config::new(port=server.addr.port()),
        connection => {
          @async.with_task_group(requests => {
            let first = requests.spawn(() => connection.prepare("first"))
            seen.get()
            assert_true(
              try {
                ignore(
                  connection.prepare(
                    "second",
                    deadline=@client.Deadline::after(40),
                  ),
                )
                false
              } catch {
                @client.TimedOut(info) =>
                  info.scope == Operation &&
                  info.phase == WaitingPrepare &&
                  !info.may_have_been_sent
                _ => false
              },
            )
            let deadline = @client.Deadline::after(1)
            @async.sleep(5)
            assert_true(
              try {
                ignore(connection.query("expired", deadline~))
                false
              } catch {
                @client.TimedOut(info) =>
                  info.scope == Operation &&
                  info.phase == WaitingSlot &&
                  !info.may_have_been_sent
                _ => false
              },
            )
            release.put(())
            ignore(first.wait())
          })
        },
      )
      worker.wait()
    })
  })
}
