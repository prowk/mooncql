///|
async test "LRU refreshes hits and eviction preserves previously returned prepared objects" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        for (name, id) in [("a", b"a"), ("b", b"b"), ("c", b"c")] {
          let prepare = receive(peer)
          assert_eq(prepare.header.opcode, 9)
          assert_eq(@codec.Reader::new(prepare.body).long_string(), name)
          respond(peer, prepare.header.stream, 8, prepared_result(id))
        }
        let execute = receive(peer)
        assert_eq(execute.header.opcode, 10)
        assert_eq(@codec.Reader::new(execute.body).short_bytes(), b"b")
        respond(peer, execute.header.stream, 8, rows_result([1], None))
        let prepare = receive(peer)
        assert_eq(@codec.Reader::new(prepare.body).long_string(), "b")
        respond(peer, prepare.header.stream, 8, prepared_result(b"b-new"))
        let execute = receive(peer)
        assert_eq(execute.header.opcode, 10)
        assert_eq(@codec.Reader::new(execute.body).short_bytes(), b"c")
        respond(peer, execute.header.stream, 8, rows_result([2], None))
        assert_eq(peer.read_some(), None)
      })
      @client.with_connection_builder(
        config=@client.ConnectionBuilder::new(
          port=server.addr.port(),
          prepared_cache_capacity=2,
        ),
        connection => {
          let a = connection.prepare("a")
          let b = connection.prepare("b")
          assert_true(physical_equal(a, connection.prepare("a")))
          let c = connection.prepare("c")
          assert_eq(connection.prepared_cache_size(), 2)
          assert_true(b.execute([Integer(1)]) is Rows(_))
          assert_true(physical_equal(a, connection.prepare("a")))
          assert_true(!physical_equal(b, connection.prepare("b")))
          assert_true(c.execute([Integer(2)]) is Rows(_))
          assert_eq(connection.prepared_cache_size(), 2)
        },
      )
      worker.wait()
    })
  })
}

///|
async test "singleflight works with disabled cache and does not serialize different statements" {
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
        let shared = receive(peer)
        assert_eq(@codec.Reader::new(shared.body).long_string(), "shared")
        seen.put(())
        let independent = receive(peer)
        assert_eq(
          @codec.Reader::new(independent.body).long_string(),
          "independent",
        )
        respond(peer, independent.header.stream, 8, prepared_result(b"other"))
        release.get()
        respond(peer, shared.header.stream, 8, prepared_result(b"shared"))
        let again = receive(peer)
        assert_eq(@codec.Reader::new(again.body).long_string(), "shared")
        respond(peer, again.header.stream, 8, prepared_result(b"second"))
        assert_eq(peer.read_some(), None)
      })
      @client.with_connection_builder(
        config=@client.ConnectionBuilder::new(
          port=server.addr.port(),
          prepared_cache_capacity=0,
        ),
        connection => {
          @async.with_task_group(requests => {
            let first = requests.spawn(() => connection.prepare("shared"))
            seen.get()
            let second = requests.spawn(() => connection.prepare("shared"))
            while connection.waiting_count() == 0 {
              @async.pause()
            }
            ignore(connection.prepare("independent"))
            release.put(())
            let a = first.wait()
            let b = second.wait()
            assert_true(physical_equal(a, b))
            assert_eq(connection.prepared_cache_size(), 0)
          })
          ignore(connection.prepare("shared"))
          assert_eq(connection.prepared_cache_size(), 0)
          assert_eq(connection.waiting_count(), 0)
        },
      )
      worker.wait()
    })
  })
}

///|
async test "prepare failure is shared by waiters then cleared for a later retry" {
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
        let w = @codec.Writer::new()
        w.i32(0x2000)
        w.string("invalid query")
        respond(peer, first.header.stream, 0, w.to_bytes())
        let retry = receive(peer)
        assert_eq(retry.header.opcode, 9)
        respond(peer, retry.header.stream, 8, prepared_result(b"retry"))
        assert_eq(peer.read_some(), None)
      })
      @client.with_connection_builder(
        config=@client.ConnectionBuilder::new(port=server.addr.port()),
        connection => {
          @async.with_task_group(requests => {
            async fn prepare() {
              try {
                ignore(connection.prepare("query"))
                false
              } catch {
                @client.Server(error) => error.code == 0x2000
                _ => false
              }
            }
            let first = requests.spawn(prepare)
            seen.get()
            let second = requests.spawn(prepare)
            let third = requests.spawn(prepare)
            while connection.waiting_count() != 2 {
              @async.pause()
            }
            release.put(())
            assert_true(first.wait())
            assert_true(second.wait())
            assert_true(third.wait())
          })
          assert_eq(connection.prepared_cache_size(), 0)
          ignore(connection.prepare("query"))
          assert_eq(connection.prepared_cache_size(), 1)
          assert_eq(connection.waiting_count(), 0)
        },
      )
      worker.wait()
    })
  })
}

///|
async test "cancelled prepare follower returns its queue budget without cancelling owner" {
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
        let prepare = receive(peer)
        seen.put(())
        release.get()
        respond(peer, prepare.header.stream, 8, prepared_result(b"owner"))
        assert_eq(peer.read_some(), None)
      })
      @client.with_connection_builder(
        config=@client.ConnectionBuilder::new(
          port=server.addr.port(),
          max_waiting=1,
        ),
        connection => {
          @async.with_task_group(requests => {
            let first = requests.spawn(() => connection.prepare("query"))
            seen.get()
            let second = requests.spawn(() => connection.prepare("query"))
            while connection.waiting_count() == 0 {
              @async.pause()
            }
            assert_true(
              try {
                ignore(connection.prepare("query"))
                false
              } catch {
                @client.Overloaded(WaitingQueueFull) => true
                _ => false
              },
            )
            second.cancel()
            ignore(second.wait()) catch {
              _ => ()
            }
            assert_eq(connection.waiting_count(), 0)
            assert_eq(connection.waiting_bytes(), 0L)
            assert_eq(connection.in_flight_count(), 1)
            release.put(())
            let prepared = first.wait()
            assert_true(physical_equal(prepared, connection.prepare("query")))
          })
        },
      )
      worker.wait()
    })
  })
}

///|
async test "cancelled prepare owner lets a waiter retry and ignores its late prepared response" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let abandoned = receive(peer)
        seen.put(())
        let retry = receive(peer)
        assert_true(abandoned.header.stream != retry.header.stream)
        respond(peer, retry.header.stream, 8, prepared_result(b"current"))
        respond(peer, abandoned.header.stream, 8, prepared_result(b"late"))
        let execute = receive(peer)
        assert_eq(execute.header.opcode, 10)
        assert_eq(@codec.Reader::new(execute.body).short_bytes(), b"current")
        respond(peer, execute.header.stream, 8, rows_result([7], None))
        assert_eq(peer.read_some(), None)
      })
      @client.with_connection_builder(
        config=@client.ConnectionBuilder::new(port=server.addr.port()),
        connection => {
          @async.with_task_group(requests => {
            let first = requests.spawn(() => connection.prepare("query"))
            seen.get()
            let second = requests.spawn(() => connection.prepare("query"))
            while connection.waiting_count() == 0 {
              @async.pause()
            }
            first.cancel()
            ignore(first.wait()) catch {
              _ => ()
            }
            let prepared = second.wait()
            assert_true(prepared.execute([Integer(7)]) is Rows(_))
            assert_eq(connection.abandoned_count(), 0)
            assert_eq(connection.prepared_cache_size(), 1)
            assert_eq(connection.waiting_count(), 0)
          })
        },
      )
      worker.wait()
    })
  })
}
