///|
async test "100 Session prepare page cancel drain close cycles return every owned resource to baseline" {
  @async.with_timeout(60000, () => {
    let retained : Array[(@client.SessionPrepared, @client.Pager)] = []
    for cycle in 0..<100 {
      @async.with_task_group(group => {
        let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
        defer server.close()
        let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
        let release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
        let worker = group.spawn(() => {
          let (tcp, _) = server.accept()
          let peer = Peer::new(tcp, compressed=cycle % 2 == 0)
          defer peer.close()
          handshake(peer)
          let prepare = receive(peer)
          assert_eq(prepare.header.opcode, 9)
          respond(peer, prepare.header.stream, 8, prepared_result(b"cycle"))
          let first = receive(peer)
          respond(
            peer,
            first.header.stream,
            8,
            rows_result([cycle], Some(b"next")),
          )
          let late = receive(peer)
          seen.put(())
          release.get()
          // 立即关闭分支允许写入失败，其余分支必须完整排空。
          if cycle % 3 == 0 {
            ignore(
              respond(
                peer,
                late.header.stream,
                8,
                rows_result([cycle + 1], None),
              ),
            ) catch {
              _ => ()
            }
          } else {
            respond(peer, late.header.stream, 8, rows_result([cycle + 1], None))
            assert_eq(peer.read_some(), None)
          }
        })
        @client.with_session(
          config=@client.SessionConfig::new(
            connection=@client.Config::new(
              port=server.addr.port(),
              compression=cycle % 2 == 0,
              prepared_cache_capacity=1,
              max_in_flight=1,
              heartbeat_interval_ms=0,
            ),
          ),
          session => {
            let prepared = session.prepare("SELECT id FROM ks.t WHERE id=?")
            let pager = prepared.pages([Integer(cycle)])
            assert_eq(pager.next().unwrap().row(0).int("id"), cycle)
            @async.with_task_group(requests => {
              let task = requests.spawn(() => pager.next())
              seen.get()
              task.cancel()
              ignore(task.wait()) catch {
                _ => ()
              }
              assert_eq(session.resources().pending, 1)
              assert_eq(session.resources().abandoned, 1)
              if cycle % 3 == 0 {
                session.close()
                release.put(())
              } else {
                release.put(())
                assert_eq(
                  session.drain(@client.Deadline::after(2000)),
                  @client.DrainOutcome::Drained,
                )
              }
            })
            let resources = session.resources()
            assert_eq(resources.active, 0)
            assert_eq(resources.pending, 0)
            assert_eq(resources.abandoned, 0)
            assert_eq(resources.in_flight, 0)
            assert_eq(resources.in_flight_bytes, 0L)
            assert_eq(resources.waiting, 0)
            assert_eq(resources.waiting_bytes, 0L)
            assert_eq(resources.background_task_handles, 0)
            assert_eq(session.budget().in_flight_bytes, 0L)
            assert_eq(session.scheduling().queued, 0)
            if cycle % 10 == 0 {
              retained.push((prepared, pager))
            }
          },
        )
        worker.wait()
      })
    }
    // 应用显式保留旧对象不会使其跨已关闭的作用域重新发起网络请求。
    for (prepared, pager) in retained {
      assert_true(
        try {
          ignore(prepared.execute([Integer(0)]))
          false
        } catch {
          @client.Closed => true
          _ => false
        },
      )
      assert_true(
        try {
          ignore(pager.next())
          false
        } catch {
          @client.Closed => true
          _ => false
        },
      )
    }
    retained.clear()
  })
}
