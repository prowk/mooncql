///|
async test "cancelling a slot waiter sends nothing and preserves the active request" {
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
        respond(peer, last.header.stream, 8, named_result("last"))
        assert_eq(peer.read_some(), None)
      })
      @client.with_serial_connection(
        config=@client.Config::new(port=server.addr.port()),
        connection => {
          @async.with_task_group(requests => {
            let first = requests.spawn(() => connection.query("first"))
            seen.get()
            let waiter = requests.spawn(() => connection.query("cancelled"))
            @async.pause()
            waiter.cancel()
            ignore(waiter.wait()) catch {
              _ => ()
            }
            assert_eq(connection.pending_count(), 1)
            assert_eq(connection.abandoned_count(), 0)
            assert_true(!connection.is_closed())
            release.put(())
            assert_true(first.wait() is SetKeyspace("first"))
          })
          assert_true(connection.query("last") is SetKeyspace("last"))
          assert_eq(connection.pending_count(), 0)
        },
      )
      worker.wait()
    })
  })
}

///|
async test "serial timeout retains a stream until its delayed response is drained" {
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
        let first = receive(peer)
        release.get()
        respond(peer, first.header.stream, 8, named_result("late"))
        let second = receive(peer)
        assert_eq(@codec.Reader::new(second.body).long_string(), "second")
        respond(peer, second.header.stream, 8, named_result("second"))
        assert_eq(peer.read_some(), None)
      })
      @client.with_serial_connection(
        config=@client.Config::new(port=server.addr.port(), timeout_ms=100),
        connection => {
          assert_true(
            try {
              ignore(connection.query("write once"))
              false
            } catch {
              @client.RequestTimedOut => true
              _ => false
            },
          )
          assert_true(!connection.is_closed())
          assert_eq(connection.abandoned_count(), 1)
          release.put(())
          assert_true(connection.query("second") is SetKeyspace("second"))
          assert_eq(connection.pending_count(), 0)
          assert_eq(connection.abandoned_count(), 0)
        },
      )
      worker.wait()
    })
  })
}

///|
async test "abandoned TTL closes an idle connection and drains pending state" {
  @async.with_timeout(3000, () => {
    @async.with_task_group(group => {
      let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        ignore(receive(peer))
        seen.put(())
        assert_eq(peer.read_some(), None)
      })
      @client.with_connection(
        config=@client.Config::new(
          port=server.addr.port(),
          abandoned_timeout_ms=50,
        ),
        connection => {
          @async.with_task_group(requests => {
            let task = requests.spawn(() => connection.query("write"))
            seen.get()
            task.cancel()
            ignore(task.wait()) catch {
              _ => ()
            }
          })
          assert_eq(connection.abandoned_count(), 1)
          while !connection.is_closed() {
            @async.sleep(10)
          }
          assert_eq(connection.pending_count(), 0)
          assert_eq(connection.abandoned_count(), 0)
        },
      )
      worker.wait()
    })
  })
}

///|
async test "exceeding abandoned count fails other pending work and returns all slots" {
  @async.with_timeout(3000, () => {
    @async.with_task_group(group => {
      let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        for _ in 0..<3 {
          ignore(receive(peer))
          seen.put(())
        }
        assert_eq(peer.read_some(), None)
      })
      @client.with_connection(
        config=@client.Config::new(port=server.addr.port(), max_abandoned=1),
        connection => {
          @async.with_task_group(requests => {
            let first = requests.spawn(() => connection.query("first"))
            seen.get()
            let second = requests.spawn(() => connection.query("second"))
            seen.get()
            let last = requests.spawn(() => {
              try {
                ignore(connection.query("last"))
                false
              } catch {
                @client.AbandonedLimitExceeded => true
                _ => false
              }
            })
            seen.get()
            first.cancel()
            ignore(first.wait()) catch {
              _ => ()
            }
            assert_eq(connection.abandoned_count(), 1)
            second.cancel()
            ignore(second.wait()) catch {
              _ => ()
            }
            assert_true(last.wait())
          })
          assert_true(connection.is_closed())
          assert_eq(connection.pending_count(), 0)
          assert_eq(connection.abandoned_count(), 0)
        },
      )
      worker.wait()
    })
  })
}

///|
async test "write lock cancellation is isolated while partial send cancellation closes" {
  @async.with_timeout(10000, () => {
    @async.with_task_group(group => {
      let header_seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let drain : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        // 只读帧头，令远大于套接字缓冲区的消息停在发送阶段。
        ignore(tcp.read_exactly(6))
        header_seen.put(())
        drain.get()
        while tcp.read_some() is Some(_) {
          ()
        }
      })
      @client.with_connection(
        config=@client.Config::new(
          port=server.addr.port(),
          max_frame_bytes=40000000,
        ),
        connection => {
          @async.with_task_group(requests => {
            let first = requests.spawn(() => {
              connection.query("large", values=[
                Bytes(Bytes::make(32000000, b'x')),
              ])
            })
            header_seen.get()
            let second = requests.spawn(() => connection.query("unsent"))
            while connection.pending_count() < 2 {
              @async.pause()
            }
            second.cancel()
            ignore(second.wait()) catch {
              _ => ()
            }
            assert_true(!connection.is_closed())
            assert_eq(connection.pending_count(), 1)
            assert_eq(connection.abandoned_count(), 0)
            first.cancel()
            ignore(first.wait()) catch {
              _ => ()
            }
            assert_true(connection.is_closed())
            assert_eq(connection.pending_count(), 0)
            drain.put(())
          })
        },
      )
      worker.wait()
    })
  })
}
