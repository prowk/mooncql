///|
fn legacy_copy_config(value : @client.Config) -> @client.Config {
  {
    host: value.host,
    port: value.port,
    username: value.username,
    password: value.password,
    timeout_ms: value.timeout_ms,
    connect_timeout_ms: value.connect_timeout_ms,
    queue_timeout_ms: value.queue_timeout_ms,
    operation_timeout_ms: value.operation_timeout_ms,
    max_frame_bytes: value.max_frame_bytes,
    max_in_flight: value.max_in_flight,
    max_in_flight_bytes: value.max_in_flight_bytes,
    max_waiting: value.max_waiting,
    max_waiting_bytes: value.max_waiting_bytes,
    overload_policy: value.overload_policy,
    throw_on_overload: value.throw_on_overload,
    compression: value.compression,
    tls: value.tls,
    prepared_cache_capacity: value.prepared_cache_capacity,
    max_abandoned: value.max_abandoned,
    abandoned_timeout_ms: value.abandoned_timeout_ms,
    event_capacity: value.event_capacity,
    heartbeat_interval_ms: value.heartbeat_interval_ms,
    heartbeat_timeout_ms: value.heartbeat_timeout_ms,
    metrics: value.metrics,
  }
}

///|
fn legacy_copy_sessionconfig(
  value : @client.SessionConfig,
) -> @client.SessionConfig {
  {
    connection: value.connection,
    contact_points: value.contact_points,
    backoff_initial_ms: value.backoff_initial_ms,
    backoff_max_ms: value.backoff_max_ms,
    jitter: value.jitter,
    stable_reset_ms: value.stable_reset_ms,
    routing: value.routing,
    discovery: value.discovery,
  }
}

///|
async test "legacy complete Config and SessionConfig retain per connection admission without a new global cap" {
  @async.with_timeout(7000, () => {
    @async.with_task_group(group => {
      let servers = [
        @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0")),
        @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0")),
      ]
      defer (for server in servers {
        server.close()
      })
      let ready : @async.Queue[Unit] = @async.Queue(kind=Blocking(2))
      let release : @async.Queue[Unit] = @async.Queue(kind=Blocking(2))
      let workers = []
      for server in servers {
        workers.push(
          group.spawn(() => {
            let (tcp, _) = server.accept()
            let peer = Peer::new(tcp)
            defer peer.close()
            handshake(peer)
            let streams = []
            for _ in 0..<65 {
              streams.push(receive(peer).header.stream)
            }
            ready.put(())
            release.get()
            for stream in streams {
              respond(peer, stream, 8, b"\x00\x00\x00\x01")
            }
            assert_eq(peer.read_some(), None)
          }),
        )
      }
      let config = legacy_copy_config(
        @client.Config::new(max_waiting=256, heartbeat_interval_ms=0),
      )
      let session_config = legacy_copy_sessionconfig(
        @client.SessionConfig::new(
          connection=config,
          contact_points=servers.map(server => {
            @client.Endpoint::new(port=server.addr.port())
          }),
        ),
      )
      @client.with_session(config=session_config, session => {
        wait_session_nodes(session, 2)
        @async.with_task_group(requests => {
          let calls = []
          for _ in 0..<130 {
            calls.push(requests.spawn(() => session.query("legacy")))
          }
          ready.get()
          ready.get()
          assert_true(session.budget().limits is None)
          assert_eq(session.budget().in_flight, 130)
          release.put(())
          release.put(())
          for call in calls {
            assert_true(call.wait() is Void)
          }
        })
        session.close()
        assert_eq(session.budget().in_flight, 0)
        assert_eq(session.resources().background_task_handles, 0)
      })
      for worker in workers {
        worker.wait()
      }
    })
  })
}
