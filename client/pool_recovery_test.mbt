///|
async test "pool connection recovery is serialized while sibling serves and schema membership ignores another slot replacement" {
  @async.with_timeout(9000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let first_seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let first_release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let fault : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let recovery_seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let recovery_release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let schema_seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let schema_release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let identified : Array[Int32] = []
      let peer_workers : Array[@async.Task[Unit]] = []
      let metrics = @client.Metrics::new()
      let worker = group.spawn(() => {
        @async.with_task_group(handlers => {
          async fn serve(peer : Peer, index : Int32) -> Unit {
            while true {
              let request = Some(receive(peer)) catch { _ => None }
              guard request is Some(request) else { return }
              let cql = @codec.Reader::new(request.body).long_string()
              if cql == "identify" {
                identified.push(index)
              }
              if cql.contains("SELECT schema_version FROM") {
                schema_seen.put(())
                schema_release.get()
                respond(
                  peer,
                  request.header.stream,
                  8,
                  schema_version_result(Some(b"aaaaaaaaaaaaaaaa")),
                )
              } else {
                respond(
                  peer,
                  request.header.stream,
                  8,
                  rows_result([index], None),
                )
              }
            }
          }
          for index in 0..<3 {
            let (tcp, _) = server.accept()
            let peer = Peer::new(tcp)
            let task = handlers.spawn(() => {
              defer peer.close()
              if index == 0 {
                first_seen.put(())
                first_release.get()
              }
              handshake(peer)
              serve(peer, index)
            })
            peer_workers.push(task)
          }
          fault.get()
          // Windows 先结束挂起读取，再由所属任务关闭句柄。
          for index in identified {
            peer_workers[index].cancel()
            ignore(peer_workers[index].wait()) catch {
              _ => ()
            }
          }
          for index in 3..<5 {
            let (tcp, _) = server.accept()
            let peer = Peer::new(tcp)
            ignore(
              handlers.spawn(() => {
                defer peer.close()
                if index == 3 {
                  recovery_seen.put(())
                  recovery_release.get()
                }
                handshake(peer)
                serve(peer, index)
              }),
            )
          }
        })
      })
      @client.with_session_builder(
        config=@client.SessionBuilder::new(
          connection=@client.ConnectionBuilder::new(
            port=server.addr.port(),
            heartbeat_interval_ms=0,
            connect_timeout_ms=2000,
            metrics~,
          ),
          connections_per_node=3,
          jitter=0.0,
        ),
        session => {
          first_seen.get()
          @async.sleep(30)
          assert_eq(session.pools()[0].connecting, 1)
          assert_eq(
            session.pools()[0].connections
            .map(slot => slot.attempts)
            .fold(init=0, (sum, n) => sum + n),
            1,
          )
          first_release.put(())
          wait_pool_ready(session, 1, 3)
          assert_eq(metrics.snapshot().reconnects, 0L)
          assert_eq(session.resources().background_task_handles, 10)
          ignore(session.query("identify"))
          ignore(session.query("identify"))
          assert_eq(identified.length(), 2)
          let stable_generation = session.pools()[0].connections[2].generation
          fault.put(())
          recovery_seen.get()
          @async.sleep(30)
          assert_eq(session.pools()[0].connecting, 1)
          assert_eq(session.pools()[0].ready, 1)
          assert_eq(
            session.pools()[0].connections
            .map(slot => slot.attempts)
            .fold(init=0, (sum, n) => sum + n),
            4,
          )
          guard session.query("healthy") is Rows(healthy) else {
            fail("healthy slot stopped during sibling recovery")
          }
          assert_eq(healthy.row(0).int("id"), 3 - identified[0] - identified[1])
          @async.with_task_group(checks => {
            let check = checks.spawn(() => session.check_schema_agreement())
            schema_seen.get()
            recovery_release.put(())
            wait_pool_ready(session, 1, 3)
            schema_release.put(())
            let agreement = check.wait()
            assert_eq(agreement.state, @client.SchemaAgreementState::Agreed)
            assert_eq(agreement.observations.length(), 1)
            assert_eq(agreement.observations[0].generation, stable_generation)
            assert_true(!agreement.membership_changed)
          })
          assert_eq(session.nodes()[0].status.generation, 5)
          assert_eq(metrics.snapshot().reconnects, 2L)
          assert_eq(session.pools()[0].connecting, 0)
          session.close()
          assert_eq(session.resources().background_task_handles, 0)
          assert_eq(session.budget().in_flight, 0)
        },
      )
      worker.wait()
    })
  })
}

///|
async test "draining an establishing pool cancels queued handshakes without starting replacement sockets" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        assert_eq(receive(peer).header.opcode, 5)
        seen.put(())
        assert_eq(peer.read_some(), None)
      })
      @client.with_session_builder(
        config=@client.SessionBuilder::new(
          connection=@client.ConnectionBuilder::new(
            port=server.addr.port(),
            connect_timeout_ms=10000,
          ),
          connections_per_node=3,
        ),
        session => {
          seen.get()
          @async.sleep(20)
          assert_eq(session.pools()[0].connecting, 1)
          let started = @async.now()
          assert_eq(
            session.drain(@client.Deadline::after(50)),
            @client.DrainOutcome::Drained,
          )
          assert_true(@async.now() - started < 1500L)
          assert_eq(session.pools()[0].connecting, 0)
          assert_true(
            session.pools()[0].connections.all(slot => slot.state == Stopped),
          )
          assert_eq(
            session.pools()[0].connections
            .map(slot => slot.attempts)
            .fold(init=0, (sum, n) => sum + n),
            1,
          )
          assert_eq(session.resources().background_task_handles, 0)
          assert_eq(session.budget().waiting, 0)
        },
      )
      worker.wait()
    })
  })
}
