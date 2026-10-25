///|
async fn with_pool_fixture(
  size : Int,
  config? : @client.SessionBuilder = @client.SessionBuilder::new(),
  serve : async (Peer, Int) -> Unit,
  body : async (@client.Session) -> Unit,
) -> Unit {
  @async.with_timeout(8000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        @async.with_task_group(handlers => {
          for index in 0..<size {
            let (tcp, _) = server.accept()
            ignore(
              handlers.spawn(() => {
                let peer = Peer::new(tcp)
                defer peer.close()
                handshake(peer)
                serve(peer, index)
              }),
            )
          }
        })
      })
      @client.with_session_builder(
        config={
          ..config,
          connection: {
            ..config.connection,
            host: "127.0.0.1",
            port: server.addr.port(),
            heartbeat_interval_ms: 0,
          },
          connections_per_node: size,
        },
        session => {
          wait_pool_ready(session, 1, size)
          body(session)
          session.close()
          assert_eq(session.resources().background_task_handles, 0)
          assert_eq(session.budget().in_flight, 0)
          assert_eq(session.budget().in_flight_bytes, 0L)
          assert_eq(session.budget().waiting, 0)
          assert_eq(session.budget().waiting_bytes, 0L)
        },
      )
      worker.wait()
    })
  })
}

///|
async test "abandoned response stays in its pool slot and one connection fault cannot cancel a sibling request" {
  let held : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
  let release_late : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
  let survivor_seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
  let survivor_release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
  let held_index = [-1]
  let survivor_index = [-1]
  let metrics = @client.Metrics::new()
  with_pool_fixture(
    2,
    config=@client.SessionBuilder::new(
      connection=@client.ConnectionBuilder::new(max_in_flight=1, metrics~),
      limits=@client.SessionLimits::new(max_in_flight=2),
      backoff_initial_ms=1000,
      backoff_max_ms=1000,
      jitter=0.0,
    ),
    (peer, index) => {
      while true {
        let request = Some(receive(peer)) catch { _ => None }
        guard request is Some(request) else { return }
        let cql = @codec.Reader::new(request.body).long_string()
        match cql {
          "held" => {
            held_index[0] = index
            held.put(())
            release_late.get()
            respond(peer, request.header.stream, 8, rows_result([99], None))
          }
          "independent" | "again" => {
            assert_true(index != held_index[0])
            respond(peer, request.header.stream, 8, rows_result([index], None))
          }
          "after drain" => {
            assert_eq(index, held_index[0])
            respond(peer, request.header.stream, 8, rows_result([index], None))
          }
          "survivor" => {
            survivor_index[0] = index
            survivor_seen.put(())
            survivor_release.get()
            respond(peer, request.header.stream, 8, rows_result([index], None))
          }
          "fail one" => {
            assert_eq(index, held_index[0])
            assert_true(index != survivor_index[0])
            return
          }
          _ => fail("unexpected pool fault request")
        }
      }
    },
    session => {
      @async.with_task_group(requests => {
        let first = requests.spawn(() => session.query("held"))
        held.get()
        first.cancel()
        ignore(first.wait()) catch {
          _ => ()
        }
        assert_eq(session.resources().abandoned, 1)
        let slots = session.pools()[0].connections
        assert_eq(slots.filter(slot => slot.abandoned == 1).length(), 1)
        assert_eq(
          slots
          .map(slot => slot.available_streams)
          .fold(init=0, (sum, n) => sum + n),
          65535,
        )
        for cql in ["independent", "again"] {
          guard session.query(cql) is Rows(page) else {
            fail("missing healthy sibling result")
          }
          assert_eq(page.row(0).int("id"), 1 - held_index[0])
        }
        assert_eq(session.budget().in_flight, 1)
        release_late.put(())
        while session.budget().in_flight > 0 {
          @async.pause()
        }
        guard session.query("after drain") is Rows(page) else {
          fail("missing drained slot result")
        }
        assert_eq(page.row(0).int("id"), held_index[0])
        let survivor = requests.spawn(() => session.query("survivor"))
        survivor_seen.get()
        assert_true(
          try {
            ignore(session.query("fail one"))
            false
          } catch {
            _ => true
          },
        )
        assert_eq(session.status().state, Ready)
        assert_eq(session.pools()[0].ready, 1)
        assert_eq(session.budget().in_flight, 1)
        survivor_release.put(())
        guard survivor.wait() is Rows(survived) else {
          fail("sibling was cancelled")
        }
        assert_eq(survived.row(0).int("id"), survivor_index[0])
        assert_eq(metrics.snapshot().reconnects, 0L)
      })
    },
  )
}

///|
async test "adding pool connections cannot expand Session request bytes or cancellation credits" {
  let charge = @protocol.query("held").body.length() + 9
  for byte_limit in [false, true] {
    let held : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
    let release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
    let seen = [0]
    let primary = [-1]
    let metrics = @client.Metrics::new()
    with_pool_fixture(
      3,
      config=@client.SessionBuilder::new(
        connection=@client.ConnectionBuilder::new(metrics~),
        limits=@client.SessionLimits::new(
          max_in_flight=if byte_limit { 128 } else { 1 },
          max_in_flight_bytes=if byte_limit { charge } else { 67108864 },
          max_waiting=1,
        ),
      ),
      (peer, index) => {
        while true {
          let request = Some(receive(peer)) catch { _ => None }
          guard request is Some(request) else { return }
          seen[0] += 1
          let cql = @codec.Reader::new(request.body).long_string()
          if cql == "held" {
            primary[0] = index
            held.put(())
            release.get()
          } else {
            assert_eq(cql, "next")
            assert_true(index != primary[0])
          }
          respond(peer, request.header.stream, 8, rows_result([index], None))
        }
      },
      session => {
        @async.with_task_group(requests => {
          let first = requests.spawn(() => session.query("held"))
          held.get()
          first.cancel()
          ignore(first.wait()) catch {
            _ => ()
          }
          assert_eq(session.budget().in_flight, 1)
          assert_eq(session.budget().in_flight_bytes, charge.to_int64())
          let next = requests.spawn(() => session.query("next"))
          while session.budget().waiting == 0 {
            @async.pause()
          }
          for _ in 0..<20 {
            assert_true(
              try {
                ignore(session.query("held"))
                false
              } catch {
                @client.SessionOverloaded(WaitingQueueFull) => true
                _ => false
              },
            )
          }
          assert_eq(seen[0], 1)
          assert_eq(session.resources().abandoned, 1)
          assert_eq(session.pools()[0].ready, 3)
          release.put(())
          assert_true(next.wait() is Rows(_))
          assert_eq(session.budget().in_flight, 0)
          assert_eq(session.budget().waiting_bytes, 0L)
          assert_eq(metrics.snapshot().peak_in_flight, 1L)
          assert_eq(metrics.snapshot().peak_in_flight_bytes, charge.to_int64())
        })
      },
    )
  }
}
