///|
async fn wait_session_nodes(session : @client.Session, count : Int32) -> Unit {
  while session.nodes().filter(node => node.status.state == Ready).length() !=
        count {
    @async.sleep(1)
  }
}

///|
fn changed_session_row(
  name : String,
  metadata : Bytes,
  value : Int32,
) -> Bytes raise {
  let w = @codec.Writer::new()
  w.i32(2)
  w.i32(9)
  w.i32(1)
  w.short_bytes(metadata)
  w.string("ks")
  w.string("t")
  w.string(name)
  w.u16(9)
  w.i32(1)
  @types.write_value(w, Integer(value))
  w.to_bytes()
}

///|
async test "one session prepared object keeps different nodes metadata and metadata changes isolated" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let a = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      let b = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer a.close()
      defer b.close()
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
        assert_session_execute(execute, b"a", b"meta-a", 2)
        respond(
          peer,
          execute.header.stream,
          8,
          changed_session_row("column-a-new", b"meta-a-new", 2),
        )
        let execute = receive(peer)
        assert_session_execute(execute, b"a", b"meta-a-new", 4)
        respond(peer, execute.header.stream, 8, session_row(4))
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
        for value in [1, 3] {
          let execute = receive(peer)
          assert_session_execute(execute, b"b", b"meta-b", value)
          respond(peer, execute.header.stream, 8, session_row(value))
        }
        assert_eq(peer.read_some(), None)
      })
      @client.with_session_builder(
        config=@client.SessionBuilder::new(contact_points=[
          @client.Endpoint::new(port=a.addr.port()),
          @client.Endpoint::new(port=b.addr.port()),
        ]),
        session => {
          wait_session_nodes(session, 2)
          let statement = session.prepare(
            "SELECT value FROM t WHERE arg=?",
            keyspace="fixed_keyspace",
          )
          let options = @protocol.QueryOptions::new(skip_metadata=true)
          let columns = []
          for value in [1, 2, 3, 4] {
            guard statement.execute([Integer(value)], options~) is Rows(page) else {
              fail("missing node row")
            }
            assert_eq(page.rows[0][0], @types.Value::Integer(value))
            columns.push(page.columns[0].name)
          }
          assert_eq(columns, [
            "column-b", "column-a-new", "column-b", "column-a-new",
          ])
          assert_eq(session.nodes()[0].status.generation, 1)
          assert_eq(session.nodes()[1].status.generation, 1)
          session.close()
          assert_true(session.nodes().all(node => node.status.state == Stopped))
        },
      )
      first.wait()
      second.wait()
    })
  })
}

///|
async test "three node session isolates failure schedules healthy nodes and rejoins recovered node" {
  @async.with_timeout(10000, () => {
    @async.with_task_group(group => {
      let servers : Array[@socket.TcpServer] = []
      for _ in 0..<3 {
        servers.push(
          @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"), reuse_addr=true),
        )
      }
      defer (for server in servers {
        server.close()
      })
      let restart : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let workers = []
      for index in 0..<3 {
        workers.push(
          group.spawn(() => {
            if index == 0 {
              {
                let (tcp, _) = servers[0].accept()
                let peer = Peer::new(tcp)
                defer peer.close()
                handshake(peer)
                let query = receive(peer)
                assert_eq(
                  @codec.Reader::new(query.body).long_string(),
                  "fail once",
                )
                servers[0].close()
              }
              restart.get()
              servers[0] = @socket.TcpServer(servers[0].addr, reuse_addr=true)
            }
            let (tcp, _) = servers[index].accept()
            let peer = Peer::new(tcp)
            defer peer.close()
            handshake(peer)
            while true {
              let request = receive(peer) catch { _ => break }
              assert_eq(request.header.opcode, 7)
              respond(
                peer,
                request.header.stream,
                8,
                named_result("node-\{index}"),
              )
            }
          }),
        )
      }
      let endpoints = servers.map(server => {
        @client.Endpoint::new(port=server.addr.port())
      })
      @client.with_session_builder(
        config=@client.SessionBuilder::new(contact_points=endpoints),
        session => {
          wait_session_nodes(session, 3)
          assert_true(
            try {
              ignore(session.query("fail once"))
              false
            } catch {
              _ => true
            },
          )
          wait_session_nodes(session, 2)
          for _ in 0..<6 {
            assert_true(
              session.query("healthy") is SetKeyspace("node-1" | "node-2"),
            )
          }
          assert_eq(session.nodes()[1].status.generation, 1)
          assert_eq(session.nodes()[2].status.generation, 1)
          restart.put(())
          wait_session_nodes(session, 3)
          assert_eq(session.nodes()[0].status.generation, 2)
          let used : Map[String, Bool] = Map([])
          for _ in 0..<3 {
            guard session.query("rejoined") is SetKeyspace(name) else {
              fail("missing coordinator marker")
            }
            used[name] = true
          }
          assert_eq(used.length(), 3)
          for server in servers {
            server.close()
          }
          for worker in workers {
            worker.cancel()
            ignore(worker.wait()) catch {
              _ => ()
            }
          }
          wait_session_nodes(session, 0)
          assert_true(
            try {
              ignore(
                session.query("all down", deadline=@client.Deadline::after(150)),
              )
              false
            } catch {
              @client.TimedOut(info) =>
                info.phase == WaitingConnection &&
                info.scope == Operation &&
                !info.may_have_been_sent
              _ => false
            },
          )
          session.close()
          assert_eq(session.active_count(), 0)
          assert_eq(session.waiting_count(), 0)
          assert_true(session.nodes().all(node => node.status.state == Stopped))
        },
      )
    })
  })
}
