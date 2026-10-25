///|
async test "one accepted logical query counts both retry RPCs while raw ERROR remains a logical failure" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let events = []
      let metrics = @client.Metrics::with_diagnostics(event => {
        events.push(event)
      })
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let first = receive(peer)
        respond(peer, first.header.stream, 0, overload_error())
        let second = receive(peer)
        respond(peer, second.header.stream, 8, b"\x00\x00\x00\x01")
        let raw = receive(peer)
        respond(peer, raw.header.stream, 0, overload_error())
        assert_eq(peer.read_some(), None)
      })
      @client.with_session_builder(
        config=@client.SessionBuilder::new(
          connection=@client.ConnectionBuilder::new(
            port=server.addr.port(),
            metrics~,
            heartbeat_interval_ms=0,
          ),
        ),
        session => {
          assert_true(
            session.query(
              "retry",
              idempotent=true,
              retry=@client.RetryPolicy::new(max_attempts=2, delay_ms=0),
            )
            is Void,
          )
          assert_true(
            session.request(@protocol.query("raw failure")).response
            is Failure(_),
          )
          session.close()
        },
      )
      worker.wait()
      let snapshot = metrics.snapshot()
      assert_eq(metrics.operations_snapshot().logical_started, 2L)
      assert_eq(metrics.operations_snapshot().logical_succeeded, 1L)
      assert_eq(metrics.operations_snapshot().logical_failed, 1L)
      assert_eq(metrics.operations_snapshot().logical_cancelled, 0L)
      assert_eq(snapshot.requests_started, 3L)
      assert_eq(snapshot.requests_succeeded, 1L)
      assert_eq(snapshot.requests_failed, 2L)
      assert_eq(metrics.operations_snapshot().retry_attempts, 1L)
      assert_true(events.any(event => event is RetryStarted(_, 2)))
      assert_true(
        events.any(event => {
          event
          is OperationFinished({ kind: QueryOperation, outcome: Succeeded, .. })
        }),
      )
      assert_true(
        events.any(event => {
          event
          is OperationFinished(
            { kind: RequestOperation, outcome: ServerError(0x1001), .. }
          )
        }),
      )
      assert_eq(
        events.filter(event => event is RpcFinished(Data, _, _)).length(),
        3,
      )
    })
  })
}

///|
async test "manual OPTIONS is data RPC while idle heartbeat creates no logical operation" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let events = []
      let metrics = @client.Metrics::with_diagnostics(event => {
        events.push(event)
      })
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        while true {
          let next = Some(receive(peer)) catch { _ => None }
          guard next is Some(request) else { return }
          assert_eq(request.header.opcode, 5)
          respond(peer, request.header.stream, 6, heartbeat_supported())
        }
      })
      @client.with_session_builder(
        config=@client.SessionBuilder::new(
          connection=@client.ConnectionBuilder::new(
            port=server.addr.port(),
            metrics~,
            heartbeat_interval_ms=20,
            heartbeat_timeout_ms=500,
          ),
        ),
        session => {
          assert_true(
            session.request(@protocol.options()).response is Supported(_),
          )
          while !events.any(event => event is RpcFinished(Heartbeat, _, _)) {
            @async.sleep(1)
          }
          assert_eq(metrics.operations_snapshot().logical_started, 1L)
          assert_eq(metrics.operations_snapshot().logical_succeeded, 1L)
          assert_true(
            events.any(event => event is RpcFinished(Data, { opcode: 5, .. }, _)),
          )
          session.close()
        },
      )
      worker.wait()
    })
  })
}

///|
async test "cancelled logical operation finishes once while its abandoned RPC still owns the stream" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let metrics = @client.Metrics::new()
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
      @client.with_session_builder(
        config=@client.SessionBuilder::new(
          connection=@client.ConnectionBuilder::new(
            port=server.addr.port(),
            metrics~,
            heartbeat_interval_ms=0,
          ),
        ),
        session => {
          @async.with_task_group(requests => {
            let task = requests.spawn(() => session.query("cancelled write"))
            seen.get()
            task.cancel()
            ignore(task.wait()) catch {
              _ => ()
            }
            assert_eq(metrics.operations_snapshot().logical_started, 1L)
            assert_eq(metrics.operations_snapshot().logical_cancelled, 1L)
            assert_eq(metrics.operations_snapshot().logical_succeeded, 0L)
            assert_eq(session.pools()[0].connections[0].abandoned, 1)
            assert_eq(session.budget().in_flight, 1)
            release.put(())
            ignore(session.drain(@client.Deadline::after(1000)))
            assert_eq(metrics.operations_snapshot().logical_cancelled, 1L)
            assert_eq(session.budget().in_flight, 0)
          })
        },
      )
      worker.wait()
    })
  })
}
