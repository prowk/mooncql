///|
async test "OPTIONS before and after startup follows v5 framing in all handshake modes" {
  for compressed in [false, true] {
    for auth in [false, true] {
      @async.with_timeout(3000, () => {
        @async.with_task_group(group => {
          let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
          defer server.close()
          let worker = group.spawn(() => {
            let (tcp, _) = server.accept()
            let socket = Peer::new(tcp, compressed~)
            defer socket.close()
            // handshake 内部先读取未套外层帧的 OPTIONS、STARTUP。
            handshake(socket, auth~)
            let options = receive(socket)
            assert_eq(options.header.opcode, 5)
            assert_eq(options.body, b"")
            let w = @codec.Writer::new()
            w.u16(1)
            w.string("CQL_VERSION")
            w.u16(1)
            w.string("3.0.0")
            w.raw(b"extension")
            respond(socket, options.header.stream, 6, w.to_bytes())
          })
          @client.with_connection_builder(
            config=@client.ConnectionBuilder::new(
              port=server.addr.port(),
              compression=compressed,
              username?=if auth { Some("user") } else { None },
              password?=if auth { Some("secret") } else { None },
            ),
            connection => {
              guard connection.request(@protocol.options()).response
                is Supported(supported) else {
                fail("expected supported")
              }
              assert_eq(supported.get("CQL_VERSION"), Some(["3.0.0"]))
            },
          )
          worker.wait()
        })
      })
    }
  }
}
