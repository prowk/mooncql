///|
fn trace_bytes(index : Int) -> Bytes {
  Bytes::from_array(
    Array::makei(16, i => if i == 15 { index.to_byte() } else { b'\x00' }),
  )
}

///|
async test "session prepared preserves initial and UNPREPARED recovery response metadata including failed reprepare" {
  for fail_prepare in [false, true] {
    @async.with_timeout(5000, () => {
      @async.with_task_group(group => {
        let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
        defer server.close()
        let worker = group.spawn(() => {
          let (tcp, _) = server.accept()
          let peer = Peer::new(tcp)
          defer peer.close()
          handshake(peer)
          let prepare = receive(peer)
          assert_eq(request_body(prepare).long_string(), "prepared")
          respond_info(
            peer,
            prepare.header.stream,
            8,
            prepared_result(b"old"),
            1,
          )
          let execute = receive(peer)
          assert_eq(request_body(execute).short_bytes(), b"old")
          respond_info(
            peer,
            execute.header.stream,
            0,
            unprepared_error(b"old"),
            2,
          )
          let prepare = receive(peer)
          assert_eq(request_body(prepare).long_string(), "prepared")
          if fail_prepare {
            respond_info(peer, prepare.header.stream, 0, overload_error(), 3)
          } else {
            respond_info(
              peer,
              prepare.header.stream,
              8,
              prepared_result(b"new"),
              3,
            )
            let execute = receive(peer)
            assert_eq(request_body(execute).short_bytes(), b"new")
            respond_info(peer, execute.header.stream, 8, session_row(7), 4)
          }
          assert_eq(peer.read_some(), None)
        })
        @client.with_session(
          config=@client.SessionConfig::new(
            connection=@client.Config::new(port=server.addr.port()),
          ),
          session => {
            let request_options = @protocol.RequestOptions::new(
              tracing=true,
              custom_payload=Map([("tag", Some(b"original"))]),
            )
            let prepared = session.prepare_with_info(
              "prepared",
              request_options~,
            )
            assert_info(prepared.info, server.addr.port(), 1)
            let options = @protocol.QueryOptions::new(
              skip_metadata=true,
              request_options~,
            )
            if fail_prepare {
              assert_true(
                try {
                  ignore(
                    prepared.value.execute_with_info([Integer(7)], options~),
                  )
                  false
                } catch {
                  @client.ExecutionError(@client.Server(error), info) => {
                    assert_eq(error.code, 0x1001)
                    assert_info(info, server.addr.port(), 3)
                    assert_eq(info.previous.length(), 1)
                    assert_info(info.previous[0], server.addr.port(), 2)
                    true
                  }
                  _ => false
                },
              )
            } else {
              let result = prepared.value.execute_with_info(
                [Integer(7)],
                options~,
              )
              assert_info(result.info, server.addr.port(), 4)
              assert_eq(result.info.attempt_count, 2)
              assert_eq(result.info.previous.length(), 2)
              assert_info(result.info.previous[0], server.addr.port(), 2)
              assert_info(result.info.previous[1], server.addr.port(), 3)
            }
          },
        )
        worker.wait()
      })
    })
  }
}

///|
async fn respond_info(
  peer : Peer,
  stream : Int,
  opcode : Int,
  body : Bytes,
  index : Int,
) -> Unit {
  let w = @codec.Writer::new()
  w.raw(trace_bytes(index))
  w.u16(1)
  w.string("warning-\{index}")
  w.u16(1)
  w.string("out")
  w.bytes(Some(@utf8.encode("payload-\{index}")))
  w.raw(body)
  let envelope = @protocol.encode_envelope(
    stream,
    opcode,
    w.to_bytes(),
    response=true,
    flags=14,
  )
  for frame in @framing.split(envelope, compressed=peer.compressed) {
    peer.write(frame)
  }
}

///|
fn assert_info(
  info : @client.ExecutionInfo,
  port : Int,
  index : Int,
) -> Unit raise {
  assert_eq(info.coordinator.port, port)
  assert_eq(info.tracing_id, Some(trace_bytes(index)))
  assert_eq(info.warnings, ["warning-\{index}"])
  assert_eq(
    info.custom_payload.get("out"),
    Some(Some(@utf8.encode("payload-\{index}"))),
  )
}

///|
fn request_body(frame : @protocol.MessageEnvelope) -> @codec.Reader raise {
  assert_eq(frame.header.flags, 6)
  let r = @codec.Reader::new(frame.body)
  assert_eq(r.u16(), 1)
  assert_eq(r.string(), "tag")
  assert_eq(r.bytes(), Some(b"original"))
  r
}

///|
async test "query prepare execute batch and both pagers retain every response extension" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let query = receive(peer)
        assert_eq(request_body(query).long_string(), "query")
        respond_info(peer, query.header.stream, 8, named_result("query"), 1)
        let prepare = receive(peer)
        assert_eq(request_body(prepare).long_string(), "prepared")
        respond_info(peer, prepare.header.stream, 8, prepared_result(b"id"), 2)
        let execute = receive(peer)
        assert_eq(execute.header.opcode, 10)
        assert_eq(request_body(execute).short_bytes(), b"id")
        respond_info(peer, execute.header.stream, 8, session_row(7), 3)
        let batch = receive(peer)
        assert_eq(batch.header.opcode, 13)
        assert_eq(request_body(batch).u8(), 0)
        respond_info(peer, batch.header.stream, 8, b"\x00\x00\x00\x01", 4)
        for index in [5, 6] {
          let page = receive(peer)
          assert_eq(request_body(page).long_string(), "pages")
          respond_info(
            peer,
            page.header.stream,
            8,
            rows_result([index], if index == 5 { Some(b"next") } else { None }),
            index,
          )
        }
        let page = receive(peer)
        assert_eq(request_body(page).short_bytes(), b"id")
        respond_info(peer, page.header.stream, 8, rows_result([7], None), 7)
        let error = receive(peer)
        assert_eq(request_body(error).long_string(), "error")
        respond_info(peer, error.header.stream, 0, overload_error(), 8)
        assert_eq(peer.read_some(), None)
      })
      @client.with_connection(
        config=@client.Config::new(port=server.addr.port()),
        connection => {
          let request_options = @protocol.RequestOptions::new(
            tracing=true,
            custom_payload=Map([("tag", Some(b"original"))]),
          )
          let options = @protocol.QueryOptions::new(request_options~)
          let query = connection.query_with_info("query", options~)
          assert_true(query.value is SetKeyspace("query"))
          assert_info(query.info, server.addr.port(), 1)
          let preparation = connection.prepare_with_info(
            "prepared",
            request_options~,
          )
          assert_info(preparation.info, server.addr.port(), 2)
          assert_true(!preparation.info.cached)
          let cached = connection.prepare_with_info(
            "prepared",
            request_options~,
          )
          assert_true(cached.info.cached)
          assert_eq(cached.info.attempt_count, 0)
          cached.info.warnings[0] = "caller edit"
          cached.info.custom_payload["out"] = Some(b"caller edit")
          assert_info(
            connection.prepare_with_info("prepared", request_options~).info,
            server.addr.port(),
            2,
          )
          let execute = preparation.value.execute_with_info(
            [Integer(7)],
            options=@protocol.QueryOptions::new(
              skip_metadata=true,
              request_options~,
            ),
          )
          assert_info(execute.info, server.addr.port(), 3)
          let batch = connection.batch_with_info([Query("write", [])], options~)
          assert_info(batch.info, server.addr.port(), 4)
          let pager = connection.pages(
            "pages",
            options=@protocol.QueryOptions::new(page_size=1, request_options~),
          )
          request_options.custom_payload["tag"] = Some(b"changed")
          for index in [5, 6] {
            let page = pager.next_with_info().unwrap()
            assert_eq(page.value.rows[0][0], @types.Value::Integer(index))
            assert_info(page.info, server.addr.port(), index)
          }
          assert_true(pager.next_with_info() is None)
          let pager = preparation.value.pages([Integer(7)], options~)
          assert_info(
            pager.next_with_info().unwrap().info,
            server.addr.port(),
            7,
          )
          assert_true(
            try {
              ignore(connection.query_with_info("error", options~))
              false
            } catch {
              @client.ExecutionError(@client.Server(error), info) => {
                assert_eq(error.code, 0x1001)
                assert_info(info, server.addr.port(), 8)
                true
              }
              _ => false
            },
          )
        },
      )
      worker.wait()
    })
  })
}

///|
async test "successful and exhausted retries retain each coordinator and response metadata" {
  for fail_all in [false, true] {
    @async.with_timeout(5000, () => {
      @async.with_task_group(group => {
        let servers = [
          @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0")),
          @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0")),
        ]
        defer (for server in servers {
          server.close()
        })
        let workers = []
        for index in 0..<2 {
          workers.push(
            group.spawn(() => {
              let (tcp, _) = servers[index].accept()
              let peer = Peer::new(tcp)
              defer peer.close()
              handshake(peer)
              let request = receive(peer)
              assert_eq(request_body(request).long_string(), "query")
              respond_info(
                peer,
                request.header.stream,
                if index == 0 || fail_all {
                  0
                } else {
                  8
                },
                if index == 0 || fail_all {
                  overload_error()
                } else {
                  rows_result([7], None)
                },
                index + 1,
              )
              assert_eq(peer.read_some(), None)
            }),
          )
        }
        @client.with_session(
          config=@client.SessionConfig::new(
            contact_points=servers.map(server => {
              @client.Endpoint::new(port=server.addr.port())
            }),
          ),
          session => {
            wait_session_nodes(session, 2)
            let options = @protocol.QueryOptions::new(
              request_options=@protocol.RequestOptions::new(
                tracing=true,
                custom_payload=Map([("tag", Some(b"original"))]),
              ),
            )
            let retry = @client.RetryPolicy::new(max_attempts=2)
            if fail_all {
              assert_true(
                try {
                  ignore(
                    session.query_with_info(
                      "query",
                      options~,
                      idempotent=true,
                      retry~,
                    ),
                  )
                  false
                } catch {
                  @client.RetryExhausted(failures) => {
                    assert_eq(failures.length(), 2)
                    for index, failure in failures {
                      assert_true(
                        failure.error is @client.Server({ code: 0x1001, .. }),
                      )
                      assert_info(
                        failure.execution_info.unwrap(),
                        servers[index].addr.port(),
                        index + 1,
                      )
                    }
                    true
                  }
                  _ => false
                },
              )
            } else {
              let result = session.query_with_info(
                "query",
                options~,
                idempotent=true,
                retry~,
              )
              assert_eq(result.info.attempt_count, 2)
              assert_eq(result.info.previous.length(), 1)
              assert_info(result.info, servers[1].addr.port(), 2)
              assert_info(result.info.previous[0], servers[0].addr.port(), 1)
            }
          },
        )
        for worker in workers {
          worker.wait()
        }
      })
    })
  }
}
