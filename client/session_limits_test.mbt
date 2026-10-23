///|
async fn with_budget_fixture(
  count : Int,
  limits : @client.SessionLimits,
  local_limit? : Int = 128,
  queue_timeout_ms? : Int = 10000,
  request_timeout_ms? : Int = 10000,
  body : async (
    @client.Session,
    @async.Queue[Int],
    Array[@async.Queue[Unit]],
    Array[(Int, String)],
  ) -> Unit,
) -> Unit {
  @async.with_timeout(7000, () => {
    @async.with_task_group(group => {
      let servers = []
      for _ in 0..<count {
        servers.push(@socket.TcpServer(@socket.Addr::parse("127.0.0.1:0")))
      }
      defer (for server in servers {
        server.close()
      })
      let seen : @async.Queue[Int] = @async.Queue(kind=Blocking(count))
      let releases : Array[@async.Queue[Unit]] = Array::makei(count, _ => {
        @async.Queue(kind=Blocking(1))
      })
      let received : Array[(Int, String)] = []
      let workers = []
      for index in 0..<count {
        workers.push(
          group.spawn(() => {
            let (tcp, _) = servers[index].accept()
            let peer = Peer::new(tcp)
            defer peer.close()
            handshake(peer)
            while true {
              let request = Some(receive(peer)) catch { _ => None }
              guard request is Some(request) else { return }
              assert_eq(request.header.opcode, 7)
              let cql = @codec.Reader::new(request.body).long_string()
              received.push((index, cql))
              if cql == "held" {
                seen.put(index)
                releases[index].get()
              }
              respond(
                peer,
                request.header.stream,
                8,
                rows_result([index], None),
              )
            }
          }),
        )
      }
      let metrics = @client.Metrics::new()
      @client.with_session(
        config=@client.SessionConfig::new(
          connection=@client.Config::new(
            max_in_flight=local_limit,
            timeout_ms=request_timeout_ms,
            operation_timeout_ms=10000,
            connect_timeout_ms=10000,
            queue_timeout_ms~,
            heartbeat_interval_ms=0,
            metrics~,
          ),
          contact_points=servers.map(server => {
            @client.Endpoint::new(port=server.addr.port())
          }),
          limits~,
        ),
        session => {
          wait_session_nodes(session, count)
          body(session, seen, releases, received)
          session.close()
          assert_eq(session.budget().in_flight, 0)
          assert_eq(session.budget().in_flight_bytes, 0L)
          assert_eq(session.budget().waiting, 0)
          assert_eq(session.budget().waiting_bytes, 0L)
          assert_eq(metrics.snapshot().in_flight, 0L)
          assert_eq(metrics.snapshot().waiting, 0L)
          assert_true(
            metrics.snapshot().peak_in_flight <= limits.max_in_flight.to_int64(),
          )
          assert_true(
            metrics.snapshot().peak_in_flight_bytes <=
            limits.max_in_flight_bytes.to_int64(),
          )
        },
      )
      for worker in workers {
        worker.wait()
      }
    })
  })
}

///|
async test "load aware selection skips saturated connections then resumes fair rotation when all candidates are free" {
  with_budget_fixture(2, @client.SessionLimits::new(), local_limit=1, (
    session,
    seen,
    releases,
    received,
  ) => {
    @async.with_task_group(requests => {
      let held = requests.spawn(() => session.query("held"))
      assert_eq(seen.get(), 0)
      for _ in 0..<6 {
        guard session.query("free") is Rows(page) else {
          fail("missing free candidate")
        }
        assert_eq(page.row(0).int("id"), 1)
      }
      assert_eq(received.filter(item => item.0 == 0).length(), 1)
      releases[0].put(())
      ignore(held.wait())
      for index in 0..<6 {
        guard session.query("fair") is Rows(page) else {
          fail("missing round robin result")
        }
        assert_eq(page.row(0).int("id"), index % 2)
      }
      assert_eq(
        received.filter(item => item.1 == "fair" && item.0 == 0).length(),
        3,
      )
      assert_eq(
        received.filter(item => item.1 == "fair" && item.0 == 1).length(),
        3,
      )
    })
  })
}

///|
async test "Session count and byte ceilings hold across three nodes queued cancellations and abandoned requests" {
  let charge = @protocol.query("held").body.length() + 9
  for byte_limit in [false, true] {
    with_budget_fixture(
      3,
      @client.SessionLimits::new(
        max_in_flight=if byte_limit { 128 } else { 2 },
        max_in_flight_bytes=if byte_limit { charge * 2 } else { 67108864 },
        max_waiting=if byte_limit { 10 } else { 1 },
        max_waiting_bytes=if byte_limit { charge } else { 67108864 },
      ),
      (session, seen, releases, received) => {
        @async.with_task_group(requests => {
          let first = requests.spawn(() => session.query("held"))
          assert_eq(seen.get(), 0)
          let second = requests.spawn(() => session.query("held"))
          assert_eq(seen.get(), 1)
          assert_eq(session.budget().in_flight, 2)
          assert_eq(session.budget().in_flight_bytes, (charge * 2).to_int64())
          let queued = requests.spawn(() => session.query("held"))
          while session.budget().waiting == 0 {
            @async.pause()
          }
          for _ in 0..<20 {
            assert_true(
              try {
                ignore(session.query("held"))
                false
              } catch {
                @client.Overloaded(reason) =>
                  reason ==
                  (if byte_limit {
                    SessionWaitingBytesFull
                  } else {
                    SessionWaitingQueueFull
                  })
                _ => false
              },
            )
          }
          assert_eq(session.budget().waiting, 1)
          assert_eq(received.length(), 2)
          queued.cancel()
          ignore(queued.wait()) catch {
            _ => ()
          }
          assert_eq(session.budget().waiting, 0)
          first.cancel()
          ignore(first.wait()) catch {
            _ => ()
          }
          assert_eq(session.resources().abandoned, 1)
          assert_eq(session.budget().in_flight, 2)
          let next = requests.spawn(() => session.query("next"))
          while session.budget().waiting == 0 {
            @async.pause()
          }
          assert_eq(received.length(), 2)
          releases[0].put(())
          guard next.wait() is Rows(page) else {
            fail("no credit returned after late reply")
          }
          assert_eq(page.row(0).int("id"), 2)
          assert_eq(session.budget().in_flight, 1)
          releases[1].put(())
          ignore(second.wait())
          assert_eq(session.budget().in_flight, 0)
          assert_eq(session.budget().in_flight_bytes, 0L)
          assert_eq(session.budget().waiting_bytes, 0L)
        })
      },
    )
  }
}

///|
async test "Session Reject reports global count and byte limits without selecting another idle node to bypass them" {
  let charge = @protocol.query("held").body.length() + 9
  for byte_limit in [false, true] {
    with_budget_fixture(
      2,
      @client.SessionLimits::new(
        max_in_flight=if byte_limit { 128 } else { 1 },
        max_in_flight_bytes=if byte_limit { charge } else { 67108864 },
        overload_policy=Reject,
      ),
      (session, seen, releases, received) => {
        @async.with_task_group(requests => {
          let first = requests.spawn(() => session.query("held"))
          assert_eq(seen.get(), 0)
          assert_true(
            try {
              ignore(session.query("held"))
              false
            } catch {
              @client.Overloaded(reason) =>
                reason ==
                (if byte_limit {
                  SessionByteLimit
                } else {
                  SessionInFlightLimit
                })
              _ => false
            },
          )
          if byte_limit {
            assert_true(
              try {
                ignore(
                  session.query("huge", values=[Bytes(Bytes::make(256, b'a'))]),
                )
                false
              } catch {
                @client.Overloaded(SessionRequestTooLarge) => true
                _ => false
              },
            )
          }
          assert_eq(received.length(), 1)
          assert_eq(session.budget().waiting, 0)
          releases[0].put(())
          ignore(first.wait())
        })
      },
    )
  }
}

///|
async test "full Session wait uses queue timeout returns all waiting bytes and leaves live requests intact" {
  with_budget_fixture(
    2,
    @client.SessionLimits::new(max_in_flight=1),
    queue_timeout_ms=50,
    (session, seen, releases, received) => {
      @async.with_task_group(requests => {
        let first = requests.spawn(() => session.query("held"))
        assert_eq(seen.get(), 0)
        assert_true(
          try {
            ignore(
              session.query("next", deadline=@client.Deadline::after(2000)),
            )
            false
          } catch {
            @client.TimedOut(info) =>
              info.scope == Queue &&
              info.phase == WaitingSlot &&
              !info.may_have_been_sent
            _ => false
          },
        )
        assert_eq(session.budget().in_flight, 1)
        assert_eq(session.budget().waiting, 0)
        assert_eq(session.budget().waiting_bytes, 0L)
        assert_eq(received.length(), 1)
        releases[0].put(())
        ignore(first.wait())
      })
    },
  )
}

///|
async test "invalid Session limits are rejected before any connection attempt" {
  for
    limits in [
      @client.SessionLimits::new(max_in_flight=0),
      @client.SessionLimits::new(max_in_flight=1048577),
      @client.SessionLimits::new(max_in_flight_bytes=8),
      @client.SessionLimits::new(max_waiting=-1),
      @client.SessionLimits::new(max_waiting=1048577),
      @client.SessionLimits::new(max_waiting_bytes=-1),
    ] {
    assert_true(
      try {
        @client.with_session(
          config=@client.SessionConfig::new(
            connection=@client.Config::new(port=1),
            limits~,
          ),
          _ => (),
        )
        false
      } catch {
        @client.Configuration(_) => true
        _ => false
      },
    )
  }
}

///|
async test "idempotent retry waits for abandoned first attempt to return its shared credit before another node sends" {
  with_budget_fixture(
    2,
    @client.SessionLimits::new(max_in_flight=1),
    request_timeout_ms=200,
    (session, seen, releases, received) => {
      @async.with_task_group(requests => {
        let operation = requests.spawn(() => {
          session.query_with_info(
            "held",
            idempotent=true,
            retry=@client.RetryPolicy::new(max_attempts=2, delay_ms=0),
            deadline=@client.Deadline::after(3000),
          )
        })
        assert_eq(seen.get(), 0)
        while session.budget().waiting == 0 {
          @async.pause()
        }
        assert_eq(received.length(), 1)
        assert_eq(session.budget().in_flight, 1)
        assert_eq(session.resources().abandoned, 1)
        releases[0].put(())
        assert_eq(seen.get(), 1)
        assert_eq(session.resources().abandoned, 0)
        assert_eq(session.budget().in_flight, 1)
        releases[1].put(())
        assert_eq(operation.wait().info.attempt_count, 2)
        assert_eq(session.budget().in_flight, 0)
        assert_eq(session.budget().waiting, 0)
      })
    },
  )
}
