///|
fn overload_error() -> Bytes raise {
  let w = @codec.Writer::new()
  w.i32(0x1001)
  w.string("busy")
  w.to_bytes()
}

///|
async test "closing session interrupts retry backoff and joins active caller promptly" {
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
        let request = receive(peer)
        respond(peer, request.header.stream, 0, overload_error())
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
                ignore(
                  session.query(
                    "SELECT x FROM t",
                    idempotent=true,
                    retry=@client.RetryPolicy::new(delay_ms=100000),
                  ),
                )
                false
              } catch {
                @client.RetryExhausted(failures) =>
                  failures.last() is Some(failure) &&
                  failure.error is @client.Closed
                _ => false
              }
            })
            seen.get()
            @async.sleep(30)
            let started = @async.now()
            session.close()
            assert_true(@async.now() - started < 1500L)
            assert_true(task.wait())
            assert_eq(session.active_count(), 0)
            assert_true(
              session.nodes().all(node => node.status.state == Stopped),
            )
          })
        },
      )
      worker.wait()
    })
  })
}

///|
fn write_timeout(kind : String) -> Bytes raise {
  let w = @codec.Writer::new()
  w.i32(0x1100)
  w.string("write timed out")
  w.u16(4)
  w.i32(1)
  w.i32(2)
  w.string(kind)
  if kind == "CAS" {
    w.u16(3)
  }
  w.to_bytes()
}

///|
async test "later retry response uses remaining deadline and late reply cannot poison subsequent queries" {
  @async.with_timeout(6000, () => {
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
        let request = receive(peer)
        @async.sleep(200)
        respond(peer, request.header.stream, 0, overload_error())
        let next = receive(peer)
        assert_eq(@codec.Reader::new(next.body).long_string(), "drain")
        respond(peer, next.header.stream, 8, b"\x00\x00\x00\x01")
        assert_eq(peer.read_some(), None)
      })
      let second = group.spawn(() => {
        let (tcp, _) = b.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let request = receive(peer)
        release.get()
        respond(peer, request.header.stream, 8, named_result("late"))
        let next = receive(peer)
        assert_eq(@codec.Reader::new(next.body).long_string(), "drain")
        respond(peer, next.header.stream, 8, b"\x00\x00\x00\x01")
        assert_eq(peer.read_some(), None)
      })
      @client.with_session(
        config=@client.SessionConfig::new(
          connection=@client.Config::new(timeout_ms=3000),
          contact_points=[
            @client.Endpoint::new(port=a.addr.port()),
            @client.Endpoint::new(port=b.addr.port()),
          ],
        ),
        session => {
          wait_session_nodes(session, 2)
          let started = @async.now()
          let failures = try {
            ignore(
              session.query(
                "SELECT x FROM t",
                idempotent=true,
                deadline=@client.Deadline::after(800),
                retry=@client.RetryPolicy::new(max_attempts=3, delay_ms=0),
              ),
            )
            fail("second attempt must use the remaining deadline")
          } catch {
            @client.RetryExhausted(failures) => failures
            error => raise error
          }
          assert_eq(failures.length(), 2)
          assert_true(
            failures[1].endpoint is Some(endpoint) &&
            endpoint.port == b.addr.port(),
          )
          assert_true(
            failures[1].error is @client.TimedOut(info) &&
            info.scope == Operation &&
            info.phase == WaitingResponse &&
            info.may_have_been_sent,
          )
          assert_true(@async.now() - started < 2000L)
          release.put(())
          assert_true(session.query("drain") is Void)
          assert_true(session.query("drain") is Void)
          assert_eq(session.active_count(), 0)
        },
      )
      first.wait()
      second.wait()
    })
  })
}

///|
async test "cancellation during retry delay stops replay and releases logical operation" {
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
        let request = receive(peer)
        respond(peer, request.header.stream, 0, overload_error())
        seen.put(())
        let next = receive(peer)
        assert_eq(@codec.Reader::new(next.body).long_string(), "after cancel")
        respond(peer, next.header.stream, 8, b"\x00\x00\x00\x01")
        assert_eq(peer.read_some(), None)
      })
      @client.with_session(
        config=@client.SessionConfig::new(
          connection=@client.Config::new(port=server.addr.port()),
        ),
        session => {
          @async.with_task_group(requests => {
            let task = requests.spawn(() => {
              session.query(
                "cancelled",
                idempotent=true,
                retry=@client.RetryPolicy::new(delay_ms=2000),
              )
            })
            seen.get()
            @async.sleep(30)
            task.cancel()
            ignore(task.wait()) catch {
              _ => ()
            }
          })
          assert_eq(session.active_count(), 0)
          assert_eq(session.waiting_count(), 0)
          assert_true(session.query("after cancel") is Void)
        },
      )
      worker.wait()
    })
  })
}

///|
async test "idempotent query retries another node with immutable named bindings" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let a = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      let b = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer a.close()
      defer b.close()
      let values : Array[@types.Value] = [Integer(7)]
      let names = ["arg"]
      let expected = @protocol.query(
        "SELECT value FROM t WHERE arg=:arg",
        values~,
        options=@protocol.QueryOptions::new(value_names=names),
      )
      let first = group.spawn(() => {
        let (tcp, _) = a.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let request = receive(peer)
        assert_eq(request.body, expected.body)
        values[0] = Integer(99)
        names[0] = "changed"
        respond(peer, request.header.stream, 0, overload_error())
        assert_eq(peer.read_some(), None)
      })
      let second = group.spawn(() => {
        let (tcp, _) = b.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let request = receive(peer)
        assert_eq(request.header.opcode, 7)
        assert_eq(request.body, expected.body)
        respond(peer, request.header.stream, 8, rows_result([7], None))
        assert_eq(peer.read_some(), None)
      })
      @client.with_session(
        config=@client.SessionConfig::new(contact_points=[
          @client.Endpoint::new(port=a.addr.port()),
          @client.Endpoint::new(port=b.addr.port()),
        ]),
        session => {
          wait_session_nodes(session, 2)
          guard session.query(
              "SELECT value FROM t WHERE arg=:arg",
              values~,
              options=@protocol.QueryOptions::new(value_names=names),
              idempotent=true,
              retry=@client.RetryPolicy::new(max_attempts=2, delay_ms=0),
            )
            is Rows(page) else {
            fail("missing retry result")
          }
          assert_eq(page.rows[0][0], @types.Value::Integer(7))
          assert_eq(session.active_count(), 0)
        },
      )
      first.wait()
      second.wait()
    })
  })
}

///|
async test "retry budget records each coordinator and original server failure" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let servers = [
        @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0")),
        @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0")),
      ]
      defer (for server in servers {
        server.close()
      })
      let workers = servers.map(server => {
        group.spawn(() => {
          let (tcp, _) = server.accept()
          let peer = Peer::new(tcp)
          defer peer.close()
          handshake(peer)
          let request = receive(peer)
          respond(peer, request.header.stream, 0, overload_error())
          assert_eq(peer.read_some(), None)
        })
      })
      @client.with_session(
        config=@client.SessionConfig::new(
          contact_points=servers.map(server => {
            @client.Endpoint::new(port=server.addr.port())
          }),
        ),
        session => {
          wait_session_nodes(session, 2)
          let failures = try {
            ignore(
              session.query(
                "SELECT x FROM t",
                idempotent=true,
                retry=@client.RetryPolicy::new(max_attempts=2, delay_ms=0),
              ),
            )
            fail("retry must exhaust")
          } catch {
            @client.RetryExhausted(failures) => failures
            error => raise error
          }
          assert_eq(failures.length(), 2)
          for index, failure in failures {
            assert_eq(failure.attempt, index + 1)
            guard failure.endpoint is Some(endpoint) else {
              fail("missing endpoint")
            }
            assert_eq(endpoint.port, servers[index].addr.port())
            assert_true(failure.may_have_been_sent)
            assert_true(failure.error is @client.Server({ code: 0x1001, .. }))
          }
          assert_eq(session.active_count(), 0)
        },
      )
      for worker in workers {
        worker.wait()
      }
    })
  })
}

///|
async test "counter conditional append and batch unknown outcomes are never replayed by default" {
  for
    cql in [
      "UPDATE counters SET n=n+1 WHERE id=1", "INSERT INTO t(id) VALUES(1) IF NOT EXISTS",
      "UPDATE t SET xs=xs+[1] WHERE id=1", "batch", "unlogged", "counter_batch",
    ] {
    @async.with_timeout(5000, () => {
      @async.with_task_group(group => {
        let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
        defer server.close()
        let is_batch = cql == "batch" ||
          cql == "unlogged" ||
          cql == "counter_batch"
        let request = if is_batch {
          @protocol.batch(
            [Query("INSERT INTO t(id) VALUES(1)", [])],
            kind=if cql == "unlogged" {
              Unlogged
            } else if cql == "counter_batch" {
              Counter
            } else {
              Logged
            },
          )
        } else {
          @protocol.query(cql)
        }
        let worker = group.spawn(() => {
          {
            let (tcp, _) = server.accept()
            let peer = Peer::new(tcp)
            defer peer.close()
            handshake(peer)
            let sent = receive(peer)
            assert_eq(sent.header.opcode, request.opcode)
            assert_eq(sent.body, request.body)
            // 模拟写入生效后响应丢失；下一条只能是业务主动发起的新查询。
          }
          let (tcp, _) = server.accept()
          let peer = Peer::new(tcp)
          defer peer.close()
          handshake(peer)
          let sent = receive(peer)
          assert_eq(
            @codec.Reader::new(sent.body).long_string(),
            "check after unknown write",
          )
          respond(peer, sent.header.stream, 8, b"\x00\x00\x00\x01")
          assert_eq(peer.read_some(), None)
        })
        @client.with_session(
          config=@client.SessionConfig::new(
            connection=@client.Config::new(port=server.addr.port()),
          ),
          session => {
            assert_true(
              try {
                // 即便调用方声明幂等，BATCH 的低层入口也禁止自动重试。
                ignore(session.request(request, idempotent=is_batch))
                false
              } catch {
                _ => true
              },
            )
            assert_true(session.query("check after unknown write") is Void)
            assert_eq(session.status().generation, 2)
          },
        )
        worker.wait()
      })
    })
  }
}

///|
async test "non simple write failures remain terminal even with explicit idempotence" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let kinds = ["COUNTER", "CAS", "BATCH", "SIMPLE"]
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        for kind in kinds {
          let request = receive(peer)
          assert_eq(@codec.Reader::new(request.body).long_string(), kind)
          respond(peer, request.header.stream, 0, write_timeout(kind))
        }
        let retry = receive(peer)
        assert_eq(@codec.Reader::new(retry.body).long_string(), "SIMPLE")
        respond(peer, retry.header.stream, 8, b"\x00\x00\x00\x01")
        assert_eq(peer.read_some(), None)
      })
      @client.with_session(
        config=@client.SessionConfig::new(
          connection=@client.Config::new(port=server.addr.port()),
        ),
        session => {
          for kind in ["COUNTER", "CAS", "BATCH"] {
            let failures = try {
              ignore(session.query(kind, idempotent=true))
              fail("unsafe write failure must surface")
            } catch {
              @client.RetryExhausted(failures) => failures
              error => raise error
            }
            assert_eq(failures.length(), 1)
            assert_true(
              failures[0].error
              is @client.Server(
                { detail: WriteTimeout(_, _, _, actual, _), .. }
              ) &&
              actual == kind,
            )
          }
          assert_true(session.query("SIMPLE", idempotent=true) is Void)
        },
      )
      worker.wait()
    })
  })
}

///|
async test "retry delay consumes original deadline and preserves unknown outcome history" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let request = receive(peer)
        respond(peer, request.header.stream, 0, overload_error())
        assert_eq(peer.read_some(), None)
      })
      @client.with_session(
        config=@client.SessionConfig::new(
          connection=@client.Config::new(port=server.addr.port()),
        ),
        session => {
          wait_session_nodes(session, 1)
          let started = @async.now()
          let failures = try {
            ignore(
              session.query(
                "SELECT x FROM t",
                idempotent=true,
                deadline=@client.Deadline::after(300),
                retry=@client.RetryPolicy::new(delay_ms=2000),
              ),
            )
            fail("deadline must expire during retry delay")
          } catch {
            @client.RetryExhausted(failures) => failures
            error => raise error
          }
          assert_eq(failures.length(), 2)
          assert_true(failures[1].endpoint is None)
          assert_true(
            failures[1].error is @client.TimedOut(info) &&
            info.scope == Operation &&
            info.phase == WaitingRetry &&
            info.may_have_been_sent,
          )
          assert_true(@async.now() - started < 1500L)
          assert_eq(session.active_count(), 0)
          assert_eq(session.waiting_count(), 0)
        },
      )
      worker.wait()
    })
  })
}

///|
async test "session prepared retry freezes bindings and uses each nodes prepared identity" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let a = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      let b = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer a.close()
      defer b.close()
      let values : Array[@types.Value] = [Integer(7)]
      let first = group.spawn(() => {
        let (tcp, _) = a.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let prepare = receive(peer)
        assert_session_prepare(prepare)
        respond(
          peer,
          prepare.header.stream,
          8,
          session_metadata(b"a", b"meta-a", "column-a"),
        )
        let execute = receive(peer)
        assert_session_execute(execute, b"a", b"meta-a", 7)
        respond(peer, execute.header.stream, 8, session_row(7))
        assert_eq(peer.read_some(), None)
      })
      let second = group.spawn(() => {
        let (tcp, _) = b.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let prepare = receive(peer)
        assert_session_prepare(prepare)
        respond(
          peer,
          prepare.header.stream,
          8,
          session_metadata(b"b", b"meta-b", "column-b"),
        )
        let execute = receive(peer)
        assert_session_execute(execute, b"b", b"meta-b", 7)
        values[0] = Integer(99)
        respond(peer, execute.header.stream, 0, overload_error())
        assert_eq(peer.read_some(), None)
      })
      @client.with_session(
        config=@client.SessionConfig::new(contact_points=[
          @client.Endpoint::new(port=a.addr.port()),
          @client.Endpoint::new(port=b.addr.port()),
        ]),
        session => {
          wait_session_nodes(session, 2)
          let statement = session.prepare(
            "SELECT value FROM t WHERE arg=?",
            keyspace="fixed_keyspace",
          )
          guard statement.execute(
              values,
              options=@protocol.QueryOptions::new(skip_metadata=true),
              idempotent=true,
              retry=@client.RetryPolicy::new(max_attempts=2, delay_ms=0),
            )
            is Rows(page) else {
            fail("missing retry row")
          }
          assert_eq(page.columns[0].name, "column-a")
          assert_eq(page.rows[0][0], @types.Value::Integer(7))
        },
      )
      first.wait()
      second.wait()
    })
  })
}
