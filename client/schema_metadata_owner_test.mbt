///|
async test "cancelled schema owner releases singleflight and its stale late version cannot replace a follower snapshot" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let catalogs = [0]
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        let old = receive(peer)
        seen.put(())
        let next = receive(peer)
        assert_true(old.header.stream != next.header.stream)
        respond(
          peer,
          next.header.stream,
          8,
          schema_version_result(Some(b"bbbbbbbbbbbbbbbb")),
        )
        respond(
          peer,
          old.header.stream,
          8,
          schema_version_result(Some(b"aaaaaaaaaaaaaaaa")),
        )
        while true {
          let request = Some(receive(peer)) catch { _ => None }
          guard request is Some(request) else { return }
          let cql = @codec.Reader::new(request.body).long_string()
          let body = if cql.contains("schema_version FROM") {
            schema_version_result(Some(b"bbbbbbbbbbbbbbbb"))
          } else {
            catalogs[0] += 1
            schema_fixture(cql, changed=true)
          }
          respond(peer, request.header.stream, 8, body)
        }
      })
      @client.with_session(
        config=@client.SessionConfig::new(
          connection=@client.Config::new(port=server.addr.port()),
        ),
        session => {
          let options = @client.SchemaOptions::new(keyspaces=["ks"])
          @async.with_task_group(requests => {
            let owner = requests.spawn(() => session.schema_metadata(options~))
            seen.get()
            let follower = requests.spawn(() => {
              session.schema_metadata(options~)
            })
            while session.waiting_count() != 1 {
              @async.pause()
            }
            owner.cancel()
            ignore(owner.wait()) catch {
              _ => ()
            }
            let result = follower.wait()
            assert_eq(result.schema_version(), b"bbbbbbbbbbbbbbbb")
            assert_eq(
              result.user_type("ks", "address").unwrap().fields.length(),
              3,
            )
            assert_eq(
              session.schema_metadata(options~).schema_version(),
              b"bbbbbbbbbbbbbbbb",
            )
            assert_eq(catalogs[0], 5)
            assert_eq(session.resources().abandoned, 0)
            assert_eq(session.resources().waiting, 0)
            assert_eq(session.resources().in_flight_bytes, 0L)
          })
        },
      )
      worker.wait()
    })
  })
}
