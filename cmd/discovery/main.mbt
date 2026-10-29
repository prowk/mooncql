///|
async fn wait_marker(directory : String, marker : String) -> Unit {
  @async.with_timeout(180000, () => {
    while !@fs.exists("\{directory}/\{marker}") {
      @async.sleep(20)
    }
  })
}

///|
async fn wait_ready(session : @client.Session, expected : Int32) -> Unit {
  @async.with_timeout(180000, () => {
    while session.nodes().filter(node => node.status.state == Ready).length() !=
          expected {
      @async.sleep(10)
    }
  }) catch {
    error => {
      let detail = match session.control_status() {
        Some(
          {
            last_error: Some(
              @client.Unexpected(message)
              | @client.Configuration(message)
            ),
            ..
          }
        ) => message
        Some({ last_error: Some(@client.Server(server)), .. }) => server.message
        Some({ last_error: Some(error), .. }) => error.to_string()
        _ => "no control failure"
      }
      fail("ready wait failed: \{detail}; original=\{error}")
    }
  }
}

///|
async fn run_probe() -> Unit {
  let directory = @env.get_env_var("CQL_DISCOVERY_DIR").unwrap()
  let ports = []
  for
    port in @env.get_env_var("CQL_CLUSTER_PORTS")
    .unwrap_or("19052,19053,19054")
    .split(",") {
    ports.push(@string.parse_int(port))
  }
  let hosts = @env.get_env_var("CQL_CLUSTER_NATIVE_HOSTS")
    .unwrap()
    .split(",")
    .map(host => host.to_owned())
    .to_array()
  assert_eq(ports.length(), 3)
  assert_eq(hosts.length(), 3)
  let metrics = @client.Metrics::new()
  let config = @client.SessionBuilder::new(
    connection=@client.ConnectionBuilder::new(
      username?=@env.get_env_var("CQL_USERNAME"),
      password?=@env.get_env_var("CQL_PASSWORD"),
      compression=@env.get_env_var("CQL_COMPRESSION") == Some("lz4"),
      operation_timeout_ms=15000,
      metrics~,
    ),
    contact_points=[@client.Endpoint::new(port=ports[0])],
    discovery=@client.DiscoveryConfig::new(
      refresh_interval_ms=30000,
      debounce_ms=50,
      address_mapper=native => {
        if native.address.length() != 4 {
          return None
        }
        let ip = "\{native.address[0].to_int()}.\{native.address[1].to_int()}.\{native.address[2].to_int()}.\{native.address[3].to_int()}"
        for index in 0..<3 {
          if ip == hosts[index] &&
            (native.port == 9042 || native.port == ports[index]) {
            return Some(@client.Endpoint::new(port=ports[index]))
          }
        }
        None
      },
    ),
    routing=@client.RoutingConfig::new("dc1"),
  )
  @client.with_session_builder(config~, session => {
    wait_ready(session, 3)
    let initial = session.topology().unwrap()
    assert_eq(initial.nodes.length(), 3)
    assert_eq(
      initial.partitioner,
      "org.apache.cassandra.dht.Murmur3Partitioner",
    )
    let seen : Map[Bytes, Bool] = Map([])
    // 通过三条业务连接独立读取 local，对照控制连接的 local/peers_v2 元数据。
    for _ in 0..<3 {
      guard session.query(
          "SELECT host_id,data_center,rack,tokens FROM system.local",
        )
        is Rows(page) else {
        fail("missing node metadata")
      }
      let id = page.get(0, "host_id")
      guard id is Uuid(uuid) else { fail("missing node UUID") }
      seen[uuid] = true
      let matches = initial.nodes.filter(node => node.host_id == uuid)
      assert_eq(matches.length(), 1)
      let node = matches[0]
      assert_eq(
        page.get(0, "data_center"),
        @types.Value::Text(node.data_center),
      )
      assert_eq(page.get(0, "rack"), @types.Value::Text(node.rack))
      guard page.get(0, "tokens") is SetValue(tokens) else {
        fail("missing tokens")
      }
      assert_eq(tokens.length(), node.tokens.length())
      for token in node.tokens {
        assert_true(tokens.contains(Text(token.to_string())))
      }
    }
    assert_eq(seen.length(), 3)
    verify_routing(session, directory)
    if @env.get_env_var("CQL_USERNAME") is Some(_) {
      ignore(
        session.query(
          "ALTER KEYSPACE system_auth WITH replication = {'class':'NetworkTopologyStrategy','dc1':3}",
        ),
      )
    }
    let original = session.control_status().unwrap()
    let endpoint = original.endpoint.unwrap()
    let victim = ports.search_by(port => port == endpoint.port).unwrap()
    @fs.write_file(
      "\{directory}/ready.json",
      "{\"victim\":\{victim},\"generation\":\{original.generation}}\n",
    )
    wait_marker(directory, "down")
    wait_ready(session, 2)
    @async.with_timeout(30000, () => {
      while true {
        let status = session.control_status().unwrap()
        if status.connected &&
          !status.stale &&
          status.generation > original.generation {
          break
        }
        @async.sleep(10)
      }
    })
    assert_true(
      session.query("SELECT release_version FROM system.local") is Rows(_),
    )
    assert_eq(session.topology().unwrap().nodes.length(), 3)
    @fs.write_file("\{directory}/recovered", b"recovered\n")
    wait_marker(directory, "up")
    wait_ready(session, 3)
    let generation = session.control_status().unwrap().generation
    session.close()
    assert_true(!session.control_status().unwrap().connected)
    assert_true(session.nodes().all(node => node.status.state == Stopped))
    assert_eq(session.active_count(), 0)
    assert_eq(session.waiting_count(), 0)
    let observed = metrics.snapshot()
    assert_true(observed.control_reconnects >= 1L)
    assert_eq(observed.in_flight, 0L)
    assert_eq(observed.in_flight_bytes, 0L)
    assert_eq(observed.waiting, 0L)
    assert_eq(observed.waiting_bytes, 0L)
    assert_eq(observed.connections_established, observed.connections_closed)
    @fs.write_file(
      "\{directory}/result.json",
      "{\"discovered\":3,\"control_generation\":\{generation},\"active\":0,\"waiting\":0}\n",
    )
    println(
      "PASS discovered 3 nodes from 1 seed, matched identities/DC/rack/tokens, replaced control connection and joined shutdown",
    )
  })
}

///|
async fn main {
  run_probe() catch {
    @client.Server(server) =>
      fail("Cassandra \{server.code}: \{server.message}")
    @client.Unexpected(message) | @client.Configuration(message) =>
      fail(message)
    @codec.CodecError(message) => fail("codec: \{message}")
    error => raise error
  }
}
