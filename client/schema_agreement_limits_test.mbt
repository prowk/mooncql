///|
async test "schema node bound refuses partial success without querying a subset" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let a = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      let b = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer a.close()
      defer b.close()
      let workers = [a, b].map(server => {
        group.spawn(() => {
          let (tcp, _) = server.accept()
          let peer = Peer::new(tcp)
          defer peer.close()
          handshake(peer)
          assert_eq(peer.read_some(), None)
        })
      })
      @client.with_session(
        config=@client.SessionConfig::new(
          contact_points=[
            @client.Endpoint::new(port=a.addr.port()),
            @client.Endpoint::new(port=b.addr.port()),
          ],
          schema_agreement=@client.SchemaAgreementConfig::new(max_nodes=1),
        ),
        session => {
          wait_session_nodes(session, 2)
          let report = session.check_schema_agreement()
          assert_eq(report.state, @client.SchemaAgreementState::Unknown)
          assert_true(report.error is Some(@client.Configuration(_)))
          assert_eq(report.observations.length(), 0)
        },
      )
      for worker in workers {
        worker.wait()
      }
    })
  })
}

///|
async test "DDL remains successful when later schema permission is denied and the driver sends it only once" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let ddl = receive(peer)
        assert_eq(
          @codec.Reader::new(ddl.body).long_string(),
          "CREATE TYPE ks.address(street text)",
        )
        respond(peer, ddl.header.stream, 8, ddl_result())
        let check = receive(peer)
        assert_eq(
          @codec.Reader::new(check.body).long_string(),
          "SELECT schema_version FROM system.local",
        )
        let error = @codec.Writer::new()
        error.i32(0x2100)
        error.string("schema access denied")
        respond(peer, check.header.stream, 0, error.to_bytes())
        let marker = receive(peer)
        assert_eq(
          @codec.Reader::new(marker.body).long_string(),
          "next business query",
        )
        respond(peer, marker.header.stream, 8, b"\x00\x00\x00\x01")
        assert_eq(peer.read_some(), None)
      })
      @client.with_session(
        config=@client.SessionConfig::new(
          connection=@client.Config::new(port=server.addr.port()),
          schema_agreement=@client.SchemaAgreementConfig::new(
            wait_after_ddl=true,
          ),
        ),
        session => {
          let execution = session.query_with_info(
            "CREATE TYPE ks.address(street text)",
            idempotent=true,
          )
          assert_true(execution.value is SchemaChanged(_))
          assert_eq(execution.info.attempt_count, 1)
          guard execution.info.schema_agreement is Some(report) else {
            fail("missing schema report")
          }
          assert_eq(report.state, @client.SchemaAgreementState::Unknown)
          assert_true(!report.timed_out)
          assert_true(
            report.observations[0].error is Some(@client.Server(error)) &&
            error.code == 0x2100,
          )
          assert_true(session.query("next business query") is Void)
        },
      )
      worker.wait()
    })
  })
}
