///|
async test "response body rows columns nodes and depth limits close connection and release resources" {
  for compressed in [false, true] {
    for kind in 0..<5 {
      @async.with_timeout(5000, () => {
        @async.with_task_group(group => {
          let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
          defer server.close()
          let worker = group.spawn(() => {
            let (tcp, _) = server.accept()
            let peer = Peer::new(tcp, compressed~)
            defer peer.close()
            handshake(peer)
            let request = receive(peer)
            let body = if kind == 0 {
              Bytes::make(400000, b'x')
            } else if kind == 4 {
              let w = @codec.Writer::new()
              w.i32(2)
              w.i32(1)
              w.i32(1)
              w.string("ks")
              w.string("t")
              w.string("nested")
              w.u16(32)
              w.u16(9)
              w.i32(1)
              @types.write_value(w, ListValue([Integer(1)]))
              w.to_bytes()
            } else {
              rows_result([1, 2, 3], None)
            }
            ignore(respond(peer, request.header.stream, 8, body)) catch {
              _ => ()
            }
          })
          let limits = @client.ResponseLimits::new(
            max_body_bytes=if kind == 0 { 256 } else { 16777216 },
            max_rows=if kind == 1 { 2 } else { 1000000 },
            max_columns=if kind == 2 { 0 } else { 65535 },
            max_value_nodes=if kind == 3 { 2 } else { 1000000 },
            max_depth=if kind == 4 { 1 } else { 32 },
          )
          @client.with_connection_builder(
            config=@client.ConnectionBuilder::new(
              port=server.addr.port(),
              compression=compressed,
            ),
            response_limits=limits,
            connection => {
              assert_true(
                try {
                  ignore(connection.query("limited"))
                  false
                } catch {
                  @codec.CodecError(_) => true
                  _ => false
                },
              )
              assert_true(connection.is_closed())
              assert_eq(connection.pending_count(), 0)
              assert_eq(connection.in_flight_bytes(), 0L)
              let memory = connection.receive_memory()
              assert_eq(memory.reassembling_bytes, 0L)
              assert_eq(memory.queued_envelope_bytes, 0L)
              assert_eq(memory.delivering_body_bytes, 0L)
            },
          )
          worker.wait()
        })
      })
    }
  }
}

///|
test "response limits validate every boundary without opening a socket" {
  for bad in [-2147483648, -1, 0] {
    assert_true(
      try {
        ignore(@client.ResponseLimits::new(max_body_bytes=bad))
        false
      } catch {
        @client.Configuration(message) => message.contains("max_body_bytes")
        _ => false
      },
    )
  }
  for
    (rows, columns, nodes, depth) in [
      (-1, 1, 1, 1),
      (1000001, 1, 1, 1),
      (0, -1, 1, 1),
      (0, 65536, 1, 1),
      (0, 0, 0, 1),
      (0, 0, 1000001, 1),
      (0, 0, 1, 0),
      (0, 0, 1, 33),
    ] {
    assert_true(
      try {
        ignore(
          @client.ResponseLimits::new(
            max_rows=rows,
            max_columns=columns,
            max_value_nodes=nodes,
            max_depth=depth,
          ),
        )
        false
      } catch {
        @client.Configuration(_) => true
        _ => false
      },
    )
  }
  ignore(
    @client.ResponseLimits::new(
      max_body_bytes=2147483647,
      max_rows=0,
      max_columns=0,
      max_value_nodes=1,
      max_depth=1,
    ),
  )
}
