///|
async test "Connection concurrent drain admits existing queue rejects new RPCs and joins resources" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let first = receive(peer)
        seen.put(())
        release.get()
        respond(peer, first.header.stream, 8, named_result("first"))
        let second = receive(peer)
        assert_eq(@codec.Reader::new(second.body).long_string(), "second")
        respond(peer, second.header.stream, 8, named_result("second"))
        assert_eq(peer.read_some(), None)
      })
      @client.with_connection(
        config=@client.Config::new(port=server.addr.port(), max_in_flight=1),
        connection => {
          @async.with_task_group(requests => {
            let first = requests.spawn(() => connection.query("first"))
            seen.get()
            let second = requests.spawn(() => connection.query("second"))
            while connection.waiting_count() != 1 {
              @async.pause()
            }
            let drain_a = requests.spawn(() => {
              connection.drain(@client.Deadline::after(2000))
            })
            while !connection.is_draining() {
              @async.pause()
            }
            let drain_b = requests.spawn(() => {
              connection.drain(@client.Deadline::after(2000))
            })
            assert_true(
              try {
                ignore(connection.query("rejected"))
                false
              } catch {
                @client.Draining => true
                _ => false
              },
            )
            release.put(())
            assert_true(first.wait() is SetKeyspace("first"))
            assert_true(second.wait() is SetKeyspace("second"))
            assert_eq(drain_a.wait(), @client.DrainOutcome::Drained)
            assert_eq(drain_b.wait(), @client.DrainOutcome::Drained)
            assert_eq(
              connection.drain(@client.Deadline::after(1)),
              @client.DrainOutcome::Drained,
            )
            assert_true(connection.is_closed())
            assert_eq(connection.pending_count(), 0)
            assert_eq(connection.waiting_count(), 0)
            assert_eq(connection.in_flight_bytes(), 0L)
          })
        },
      )
      worker.wait()
    })
  })
}

///|
async test "Session drain permits accepted UNPREPARED recovery but rejects new query prepare execute and batch" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let prepare = receive(peer)
        respond(peer, prepare.header.stream, 8, prepared_result(b"old"))
        let execute = receive(peer)
        seen.put(())
        release.get()
        respond(peer, execute.header.stream, 0, unprepared_error(b"old"))
        let prepare = receive(peer)
        assert_eq(prepare.header.opcode, 9)
        respond(peer, prepare.header.stream, 8, prepared_result(b"new"))
        let execute = receive(peer)
        assert_eq(@codec.Reader::new(execute.body).short_bytes(), b"new")
        respond(peer, execute.header.stream, 8, rows_result([7], None))
        assert_eq(peer.read_some(), None)
      })
      @client.with_session(
        config=@client.SessionConfig::new(
          connection=@client.Config::new(port=server.addr.port()),
        ),
        session => {
          let prepared = session.prepare("statement")
          @async.with_task_group(requests => {
            let task = requests.spawn(() => prepared.execute([Integer(7)]))
            seen.get()
            let drain = requests.spawn(() => {
              session.drain(@client.Deadline::after(2000))
            })
            while !session.is_draining() {
              @async.pause()
            }
            assert_true(
              try {
                ignore(session.query("new"))
                false
              } catch {
                @client.Draining => true
                _ => false
              },
            )
            assert_true(
              try {
                ignore(session.prepare("new"))
                false
              } catch {
                @client.Draining => true
                _ => false
              },
            )
            assert_true(
              try {
                ignore(prepared.execute([Integer(8)]))
                false
              } catch {
                @client.Draining => true
                _ => false
              },
            )
            assert_true(
              try {
                session.batch([prepared.bind_batch([Integer(8)])])
                false
              } catch {
                @client.Draining => true
                _ => false
              },
            )
            release.put(())
            assert_true(
              task.wait() is Rows(page) &&
              page.get(0, "id") == @types.Value::Integer(7),
            )
            assert_eq(drain.wait(), @client.DrainOutcome::Drained)
            assert_eq(session.resources().active, 0)
            assert_eq(session.resources().background_task_handles, 0)
            assert_true(
              session
              .nodes()
              .all(node => {
                node.status.state == Stopped && node.status.attempts == 1
              }),
            )
          })
        },
      )
      worker.wait()
    })
  })
}

///|
async test "Session concurrent drain deadline cancels pending and queued operations returns one outcome and zero resources" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        ignore(receive(peer))
        seen.put(())
        assert_eq(peer.read_some(), None)
      })
      @client.with_session(
        config=@client.SessionConfig::new(
          connection=@client.Config::new(
            port=server.addr.port(),
            max_in_flight=1,
          ),
        ),
        session => {
          @async.with_task_group(requests => {
            let first = requests.spawn(() => {
              try {
                ignore(session.query("first"))
                false
              } catch {
                _ => true
              }
            })
            seen.get()
            let second = requests.spawn(() => {
              try {
                ignore(session.query("second"))
                false
              } catch {
                _ => true
              }
            })
            while session.resources().waiting != 1 {
              @async.pause()
            }
            let drain_a = requests.spawn(() => {
              session.drain(@client.Deadline::after(80))
            })
            while !session.is_draining() {
              @async.pause()
            }
            let drain_b = requests.spawn(() => {
              session.drain(@client.Deadline::after(2000))
            })
            assert_eq(drain_a.wait(), @client.DrainOutcome::DeadlineReached(2))
            assert_eq(drain_b.wait(), @client.DrainOutcome::DeadlineReached(2))
            assert_true(first.wait())
            assert_true(second.wait())
            session.close()
            let resources = session.resources()
            assert_eq(resources.active, 0)
            assert_eq(resources.pending, 0)
            assert_eq(resources.abandoned, 0)
            assert_eq(resources.in_flight, 0)
            assert_eq(resources.in_flight_bytes, 0L)
            assert_eq(resources.waiting, 0)
            assert_eq(resources.waiting_bytes, 0L)
            assert_eq(resources.background_task_handles, 0)
          })
        },
      )
      worker.wait()
    })
  })
}

///|
async test "Connection drain waits for an abandoned late response instead of reusing its stream" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
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
      @client.with_connection(
        config=@client.Config::new(port=server.addr.port()),
        connection => {
          @async.with_task_group(requests => {
            let task = requests.spawn(() => connection.query("cancel"))
            seen.get()
            task.cancel()
            ignore(task.wait()) catch {
              _ => ()
            }
            assert_eq(connection.abandoned_count(), 1)
            let drain = requests.spawn(() => {
              connection.drain(@client.Deadline::after(2000))
            })
            while !connection.is_draining() {
              @async.pause()
            }
            assert_true(!connection.is_closed())
            release.put(())
            assert_eq(drain.wait(), @client.DrainOutcome::Drained)
            assert_eq(connection.abandoned_count(), 0)
            assert_eq(connection.in_flight_bytes(), 0L)
          })
        },
      )
      worker.wait()
    })
  })
}

///|
async test "cancelled Session drain and immediate close interrupt accepted work and join without reconnecting" {
  for cancel in [false, true] {
    @async.with_timeout(5000, () => {
      @async.with_task_group(group => {
        let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
        defer server.close()
        let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
        let worker = group.spawn(() => {
          let (tcp, _) = server.accept()
          let peer = Peer::new(tcp)
          defer peer.close()
          handshake(peer)
          ignore(receive(peer))
          seen.put(())
          assert_eq(peer.read_some(), None)
        })
        @client.with_session(
          config=@client.SessionConfig::new(
            connection=@client.Config::new(port=server.addr.port()),
          ),
          session => {
            @async.with_task_group(requests => {
              let task = requests.spawn(() => {
                try {
                  ignore(session.query("first"))
                  false
                } catch {
                  _ => true
                }
              })
              seen.get()
              let drain = requests.spawn(() => {
                session.drain(@client.Deadline::after(2000))
              })
              while !session.is_draining() {
                @async.pause()
              }
              if cancel {
                drain.cancel()
                ignore(drain.wait()) catch {
                  _ => ()
                }
              } else {
                session.close()
                assert_eq(drain.wait(), @client.DrainOutcome::Interrupted(1))
              }
              assert_true(task.wait())
              assert_true(session.is_closed())
              assert_eq(session.resources().active, 0)
              assert_eq(session.resources().background_task_handles, 0)
              assert_eq(
                session.drain(@client.Deadline::after(1)),
                @client.DrainOutcome::Interrupted(1),
              )
            })
          },
        )
        worker.wait()
      })
    })
  }
}
