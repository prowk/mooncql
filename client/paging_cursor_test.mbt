///|
fn cursor_query(
  message : @protocol.MessageEnvelope,
  state : Bytes?,
) -> Unit raise {
  let reader = @codec.Reader::new(message.body)
  assert_eq(reader.long_string(), "SELECT id FROM ks.t WHERE id=?")
  assert_eq(reader.u16(), 10)
  assert_eq(reader.i32(), if state is Some(_) { 13 } else { 5 })
  assert_eq(reader.u16(), 1)
  assert_eq(reader.bytes(), Some(b"\x00\x00\x00\x2a"))
  assert_eq(reader.i32(), 2)
  if state is Some(_) {
    assert_eq(reader.bytes(), state)
  }
  reader.finish()
}

///|
async test "cursor restores on another connection rejects changed context and does not advance on failure" {
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
          let request = receive(peer)
          cursor_query(request, None)
          respond(
            peer,
            request.header.stream,
            8,
            rows_result([1], Some(b"one")),
          )
          assert_eq(peer.read_some(), None)
        }
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let request = receive(peer)
        cursor_query(request, Some(b"one"))
        respond(peer, request.header.stream, 0, overload_error())
        let request = receive(peer)
        cursor_query(request, Some(b"one"))
        respond(peer, request.header.stream, 8, rows_result([], Some(b"two")))
        let request = receive(peer)
        cursor_query(request, Some(b"two"))
        // 相同续读状态属于失败，也不能提前将 Pager 标记完成。
        respond(peer, request.header.stream, 8, rows_result([99], Some(b"two")))
        let request = receive(peer)
        cursor_query(request, Some(b"two"))
        respond(peer, request.header.stream, 8, rows_result([42], None))
        assert_eq(peer.read_some(), None)
      })
      let cql = "SELECT id FROM ks.t WHERE id=?"
      let values : Array[@types.Value] = [Integer(42)]
      let options = @protocol.QueryOptions::new(page_size=2)
      let saved = @client.with_connection(
        config=@client.Config::new(port=server.addr.port()),
        connection => {
          let pager = connection.pages(cql, values~, options~)
          let initial = pager.cursor().to_bytes()
          assert_true(!pager.cursor().is_done())
          assert_eq(pager.next().unwrap().row(0).int("id"), 1)
          let saved = pager.cursor().to_bytes()
          assert_true(saved != initial)
          saved
        },
      )
      let cursor = @client.PagingCursor::from_bytes(saved)
      @client.with_connection(
        config=@client.Config::new(port=server.addr.port()),
        connection => {
          assert_true(
            try {
              ignore(connection.pages(cql + " ", values~, options~, cursor~))
              false
            } catch {
              @client.Configuration(_) => true
              _ => false
            },
          )
          assert_true(
            try {
              ignore(
                connection.pages(cql, values=[Integer(43)], options~, cursor~),
              )
              false
            } catch {
              @client.Configuration(_) => true
              _ => false
            },
          )
          for
            changed in [
              { ..options, keyspace: Some("other"), },
              { ..options, page_size: Some(3), },
              { ..options, consistency: Quorum, },
              { ..options, serial_consistency: Some(Serial), },
              { ..options, timestamp: Some(1L), },
              { ..options, now_in_seconds: Some(1), },
              { ..options, skip_metadata: true, },
              { ..options, value_names: Some(["id"]), },
              {
                ..options,
                request_options: Some(
                  @protocol.RequestOptions::new(tracing=true),
                ),
              },
              {
                ..options,
                request_options: Some(
                  @protocol.RequestOptions::new(
                    custom_payload=Map([("x", Some(b"y"))]),
                  ),
                ),
              },
              { ..options, paging_state: Some(b"ambiguous"), },
            ] {
            assert_true(
              try {
                ignore(connection.pages(cql, values~, options=changed, cursor~))
                false
              } catch {
                @client.Configuration(_) => true
                _ => false
              },
            )
          }
          let pager = connection.pages(cql, values~, options~, cursor~)
          let expired = @client.Deadline::after(1)
          @async.sleep(5)
          assert_true(
            try {
              ignore(pager.next(deadline=expired))
              false
            } catch {
              @client.TimedOut(_) => true
              _ => false
            },
          )
          assert_eq(pager.cursor().to_bytes(), saved)
          assert_true(!pager.cursor().to_repr().to_string().contains("SELECT"))
          assert_true(
            try {
              ignore(pager.next())
              false
            } catch {
              @client.Server(_) => true
              _ => false
            },
          )
          assert_eq(pager.cursor().to_bytes(), saved)
          assert_eq(pager.next().unwrap().rows.length(), 0)
          let before = pager.cursor().to_bytes()
          assert_true(
            try {
              ignore(pager.next())
              false
            } catch {
              @client.Unexpected(_) => true
              _ => false
            },
          )
          assert_eq(pager.cursor().to_bytes(), before)
          assert_eq(pager.next().unwrap().row(0).int("id"), 42)
          assert_true(pager.cursor().is_done())
          let done = @client.PagingCursor::from_bytes(pager.cursor().to_bytes())
          assert_true(
            connection.pages(cql, values~, options~, cursor=done).next() is None,
          )
          assert_true(pager.next() is None)
        },
      )
      worker.wait()
    })
  })
}

///|
async test "cancelled next preserves cursor and busy calls cannot capture or advance it" {
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
        let request = receive(peer)
        cursor_query(request, None)
        seen.put(())
        release.get()
        respond(
          peer,
          request.header.stream,
          8,
          rows_result([99], Some(b"late")),
        )
        let request = receive(peer)
        cursor_query(request, None)
        respond(peer, request.header.stream, 8, rows_result([42], None))
        assert_eq(peer.read_some(), None)
      })
      @client.with_serial_connection(
        config=@client.Config::new(port=server.addr.port()),
        connection => {
          let pager = connection.pages(
            "SELECT id FROM ks.t WHERE id=?",
            values=[Integer(42)],
            options=@protocol.QueryOptions::new(page_size=2),
          )
          let before = pager.cursor().to_bytes()
          @async.with_task_group(requests => {
            let task = requests.spawn(() => pager.next())
            seen.get()
            assert_true(
              try {
                ignore(pager.next())
                false
              } catch {
                @client.Configuration(_) => true
                _ => false
              },
            )
            assert_true(
              try {
                ignore(pager.cursor())
                false
              } catch {
                @client.Configuration(_) => true
                _ => false
              },
            )
            task.cancel()
            ignore(task.wait()) catch {
              _ => ()
            }
            assert_eq(pager.cursor().to_bytes(), before)
            release.put(())
            assert_eq(pager.next().unwrap().row(0).int("id"), 42)
            assert_eq(connection.pending_count(), 0)
          })
        },
      )
      worker.wait()
    })
  })
}

///|
test "cursor decoder rejects unsupported truncated and contradictory input" {
  for
    bytes in [
      b"", b"MCQLPG02", b"MCQLPG01\xff\xff\xff\xff\x00\xff\xff\xff\xff", b"MCQLPG01\x00\x00\x00\x01x\x02\xff\xff\xff\xff",
      b"MCQLPG01\x00\x00\x00\x01x\x01\x00\x00\x00\x00", b"MCQLPG01\x00\x00\x00\x01x\x00\xff\xff\xff\xffextra",
    ] {
    assert_true(
      try {
        ignore(@client.PagingCursor::from_bytes(bytes))
        false
      } catch {
        _ => true
      },
    )
  }
}
