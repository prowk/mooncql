///|
fn blob_page(state : Bytes?, omit : Bool) -> Bytes raise {
  let w = @codec.Writer::new()
  w.i32(2)
  w.i32((if omit { 4 } else { 1 }) | (if state is Some(_) { 2 } else { 0 }))
  w.i32(1)
  if state is Some(_) {
    w.bytes(state)
  }
  if !omit {
    w.string("ks")
    w.string("t")
    w.string("blob")
    w.u16(3)
  }
  w.i32(1)
  @types.write_value(w, Bytes(Bytes::make(400000, b'x')))
  w.to_bytes()
}

///|
async test "three slow pagers retain application pages while driver receive ownership returns to zero" {
  for trial in 0..<3 {
    @async.with_timeout(5000, () => {
      @async.with_task_group(group => {
        let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
        defer server.close()
        let worker = group.spawn(() => {
          let (tcp, _) = server.accept()
          let peer = Peer::new(tcp)
          defer peer.close()
          handshake(peer)
          for page in 0..<2 {
            let streams = []
            for _ in 0..<3 {
              streams.push(receive(peer).header.stream)
            }
            let body = blob_page(
              if page == 0 {
                Some(b"next")
              } else {
                None
              },
              page == 1,
            )
            let messages = @codec.Writer::new()
            for stream in streams {
              for
                frame in @framing.split(
                  @protocol.encode_envelope(stream, 8, body, response=true),
                ) {
                messages.raw(frame)
              }
            }
            // TCP 合并发送，但每个分片帧仅属于一条 envelope；两页之间显式暂停。
            peer.write(messages.to_bytes())
          }
          assert_eq(peer.read_some(), None)
        })
        @client.with_connection_builder(
          config=@client.ConnectionBuilder::new(port=server.addr.port()),
          connection => {
            let pagers = Array::makei(3, index => {
              connection.pages(
                index.to_string(),
                options=@protocol.QueryOptions::new(skip_metadata=true),
              )
            })
            let held : Array[@protocol.Page] = []
            for _ in 0..<2 {
              async fn fetch(index : Int32) -> Unit {
                let page = pagers[index].next().unwrap()
                assert_eq(page.row(0).bytes("blob").length(), 400000)
                held.push(page)
              }
              ignore(
                @async.all(
                  Array::makei(3, index => () => fetch(index)),
                  max_concurrent=3,
                ),
              )
              let memory = connection.receive_memory()
              assert_eq(memory.delivering_body_bytes, 0L)
              assert_eq(memory.queued_envelope_bytes, 0L)
              assert_eq(memory.reassembling_bytes, 0L)
              assert_true(memory.peak_wire_bytes >= 400000L)
              assert_true(memory.peak_wire_bytes <= 1201000L)
              // 页由调用方保留；yield 不会使接收循环重新取得这些结果的所有权。
              @async.pause()
            }
            assert_eq(held.length(), 6)
            for pager in pagers {
              assert_true(pager.next() is None)
            }
            let memory = connection.receive_memory()
            println(
              "pager-memory trial=\{trial} peak_wire_bytes=\{memory.peak_wire_bytes} peak_delivery_bytes=\{memory.peak_delivering_body_bytes} caller_blob_bytes=2400000 decode_ms=\{memory.decode_ms}",
            )
            held.clear()
            assert_eq(connection.in_flight_bytes(), 0L)
          },
        )
        worker.wait()
      })
    }) catch {
      @codec.CodecError(message) => fail(message)
      error => raise error
    }
  }
}
