///|
fn expected_session_batch(
  id : Bytes,
  kind : @protocol.BatchType,
) -> @protocol.Request raise {
  @protocol.batch(
    [Query("plain", [Integer(1)]), Prepared(id, [Integer(7)])],
    kind~,
    options=@protocol.QueryOptions::new(keyspace="ks"),
  )
}

///|
async test "Session batch prepares on the selected coordinator freezes values and preserves execution info for all kinds" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let a = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      let b = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer a.close()
      defer b.close()
      let values : Array[@types.Value] = [Integer(7)]
      let plain : Array[@types.Value] = [Integer(1)]
      let first = group.spawn(() => {
        let (tcp, _) = a.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let prepare = receive(peer)
        assert_eq(prepare.header.opcode, 9)
        respond(peer, prepare.header.stream, 8, prepared_result(b"a"))
        let batch = receive(peer)
        assert_eq(batch.body, expected_session_batch(b"a", Unlogged).body)
        respond_info(peer, batch.header.stream, 8, b"\x00\x00\x00\x01", 4)
        assert_eq(peer.read_some(), None)
      })
      let second = group.spawn(() => {
        let (tcp, _) = b.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let prepare = receive(peer)
        assert_eq(prepare.header.opcode, 9)
        let reader = @codec.Reader::new(prepare.body)
        assert_eq(reader.long_string(), "prepared")
        assert_eq(reader.i32(), 1)
        assert_eq(reader.string(), "ks")
        reader.finish()
        values[0] = Integer(99)
        plain[0] = Integer(99)
        respond(peer, prepare.header.stream, 8, prepared_result(b"b"))
        for kind in [@protocol.BatchType::Logged, Counter] {
          let batch = receive(peer)
          assert_eq(batch.header.opcode, 13)
          assert_eq(batch.body, expected_session_batch(b"b", kind).body)
          respond_info(peer, batch.header.stream, 8, b"\x00\x00\x00\x01", 5)
        }
        assert_eq(peer.read_some(), None)
      })
      @client.with_session(
        config=@client.SessionConfig::new(contact_points=[
          @client.Endpoint::new(port=a.addr.port()),
          @client.Endpoint::new(port=b.addr.port()),
        ]),
        session => {
          wait_session_nodes(session, 2)
          let prepared = session.prepare("prepared", keyspace="ks")
          let batch = [
            @client.SessionBatchStatement::query("plain", values=plain),
            prepared.bind_batch(values),
          ]
          for
            (kind, port, previous) in [
              (@protocol.BatchType::Logged, b.addr.port(), 1),
              (Unlogged, a.addr.port(), 0),
              (Counter, b.addr.port(), 0),
            ] {
            let execution = session.batch_with_info(
              batch,
              kind~,
              options=@protocol.QueryOptions::new(keyspace="ks"),
            )
            assert_eq(execution.info.coordinator.port, port)
            assert_eq(execution.info.attempt_count, 1)
            assert_eq(execution.info.previous.length(), previous)
            assert_eq(execution.info.warnings.length(), 1)
          }
          assert_eq(session.active_count(), 0)
        },
      )
      first.wait()
      second.wait()
    })
  })
}

///|
async test "Session batch does not replay unknown outcomes or UNPREPARED and refreshes IDs only for explicit new batches" {
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
          let prepare = receive(peer)
          respond(peer, prepare.header.stream, 8, prepared_result(b"old"))
          let batch = receive(peer)
          assert_eq(batch.body, expected_session_batch(b"old", Logged).body)
          // 完整接收但不给响应：整批结果未知，不允许后台重放。
        }
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let marker = receive(peer)
        assert_eq(marker.header.opcode, 7)
        assert_eq(
          @codec.Reader::new(marker.body).long_string(),
          "explicit marker",
        )
        respond(peer, marker.header.stream, 8, b"\x00\x00\x00\x01")
        let prepare = receive(peer)
        assert_eq(prepare.header.opcode, 9)
        respond(peer, prepare.header.stream, 8, prepared_result(b"new"))
        let batch = receive(peer)
        assert_eq(batch.body, expected_session_batch(b"new", Logged).body)
        respond(peer, batch.header.stream, 0, unprepared_error(b"new"))
        let marker = receive(peer)
        assert_eq(marker.header.opcode, 7)
        assert_eq(
          @codec.Reader::new(marker.body).long_string(),
          "after unprepared",
        )
        respond(peer, marker.header.stream, 8, b"\x00\x00\x00\x01")
        assert_eq(peer.read_some(), None)
      })
      @client.with_session(
        config=@client.SessionConfig::new(
          connection=@client.Config::new(port=server.addr.port()),
        ),
        session => {
          let prepared = session.prepare("prepared", keyspace="ks")
          let batch = [
            @client.SessionBatchStatement::query("plain", values=[Integer(1)]),
            prepared.bind_batch([Integer(7)]),
          ]
          assert_true(
            try {
              session.batch(
                batch,
                options=@protocol.QueryOptions::new(keyspace="ks"),
              )
              false
            } catch {
              _ => true
            },
          )
          assert_true(session.query("explicit marker") is Void)
          assert_true(
            try {
              session.batch(
                batch,
                options=@protocol.QueryOptions::new(keyspace="ks"),
              )
              false
            } catch {
              @client.Server(error) =>
                error.detail is Unprepared(id) && id == b"new"
              _ => false
            },
          )
          assert_true(session.query("after unprepared") is Void)
          assert_eq(session.status().generation, 2)
          assert_eq(session.resources().pending, 0)
        },
      )
      worker.wait()
    })
  })
}

///|
async test "Session batch shares one deadline across all preparations and sends no batch when it expires" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let a = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      let b = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer a.close()
      defer b.close()
      let release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let first = group.spawn(() => {
        let (tcp, _) = a.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        for id in [b"a-one", b"a-two"] {
          let prepare = receive(peer)
          assert_eq(prepare.header.opcode, 9)
          respond(peer, prepare.header.stream, 8, prepared_result(id))
        }
        assert_eq(peer.read_some(), None)
      })
      let second = group.spawn(() => {
        let (tcp, _) = b.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let marker = receive(peer)
        assert_eq(marker.header.opcode, 7)
        assert_eq(@codec.Reader::new(marker.body).long_string(), "marker")
        respond(peer, marker.header.stream, 8, b"\x00\x00\x00\x01")
        let prepare = receive(peer)
        @async.sleep(100)
        respond(peer, prepare.header.stream, 8, prepared_result(b"b-one"))
        let prepare = receive(peer)
        assert_eq(prepare.header.opcode, 9)
        release.get()
        respond(peer, prepare.header.stream, 8, prepared_result(b"b-two-again"))
        assert_eq(peer.read_some(), None)
      })
      @client.with_session(
        config=@client.SessionConfig::new(contact_points=[
          @client.Endpoint::new(port=a.addr.port()),
          @client.Endpoint::new(port=b.addr.port()),
        ]),
        session => {
          wait_session_nodes(session, 2)
          let one = session.prepare("one")
          assert_true(session.query("marker") is Void)
          let two = session.prepare("two")
          // 两次准备均在 a 上；本批次选择 b，必须在 b 重新准备两条语句。
          let started = @async.now()
          assert_true(
            try {
              session.batch(
                [one.bind_batch([Integer(1)]), two.bind_batch([Integer(2)])],
                deadline=@client.Deadline::after(150),
              )
              false
            } catch {
              @client.TimedOut(_) => true
              _ => false
            },
          )
          assert_true(@async.now() - started < 1000L)
          release.put(())
          // 排空迟到 PREPARED 后再退出作用域，避免测试服务端向已关闭连接写入。
          while session.resources().abandoned > 0 {
            @async.pause()
          }
        },
      )
      first.wait()
      second.wait()
    })
  })
}
