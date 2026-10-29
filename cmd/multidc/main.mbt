///|
async fn marker(directory : String, name : String) -> Unit {
  @async.with_timeout(180000, () => {
    while !@fs.exists("\{directory}/\{name}") {
      @async.sleep(20)
    }
  })
}

///|
async fn ready(session : @client.Session, count : Int32) -> Unit {
  @async.with_timeout(60000, () => {
    while session.nodes().filter(node => node.status.state == Ready).length() !=
          count ||
          session.control_status().unwrap().stale {
      @async.sleep(20)
    }
  })
}

///|
async fn replicas(session : @client.Session, directory : String) -> Unit {
  let snapshot = session.topology().unwrap()
  let ring = @routing.Ring::new(
    snapshot.nodes.map(node => {
      host_id: node.host_id,
      data_center: node.data_center,
      rack: node.rack,
      tokens: node.tokens,
    }),
    snapshot.partitioner,
  ).unwrap()
  let records = []
  for id in 0..<64 {
    let key = @types.encode_scalar(Integer(id))
    let token = @routing.murmur3_token(key)
    let hint = @client.RoutingHint::new("mooncql_multidc", key)
    guard session.query(
        "SELECT host_id,data_center FROM system.local",
        routing=hint,
      )
      is Rows(page) else {
      fail("missing multi-DC coordinator")
    }
    guard page.get(0, "host_id") is Uuid(coordinator) else {
      fail("missing host ID")
    }
    assert_eq(page.get(0, "data_center"), @types.Value::Text("dc1"))
    let ids = ring
      .replicas(token, snapshot.keyspaces["mooncql_multidc"])
      .unwrap()
    assert_eq(ids.length(), 3)
    assert_true(ids.contains(coordinator))
    let encoded = ids.map(id => "\"\{@hex.encode(id)}\"")
    records.push(
      "{\"keyspace\":\"mooncql_multidc\",\"key\":\"\{@hex.encode(key)}\",\"token\":\{token},\"replicas\":[\{encoded.join(",")}],\"coordinator\":\"\{@hex.encode(coordinator)}\"}",
    )
  }
  @fs.write_file("\{directory}/routing.json", "[\{records.join(",")}]\n")
}

///|
async fn run() -> Unit {
  let directory = @env.get_env_var("CQL_MULTIDC_DIR").unwrap()
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
  let discovery = @client.DiscoveryConfig::new(
    refresh_interval_ms=1000,
    debounce_ms=10,
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
  )
  let connection = @client.ConnectionBuilder::new(
    operation_timeout_ms=5000,
    connect_timeout_ms=2000,
    heartbeat_interval_ms=500,
    heartbeat_timeout_ms=1000,
    compression=true,
  )
  let contacts = [@client.Endpoint::new(port=ports[0])]
  @client.with_session_builder(
    config=@client.SessionBuilder::new(
      connection~,
      contact_points=contacts,
      discovery~,
      routing=@client.RoutingConfig::new("dc1"),
    ),
    local_session => {
      @client.with_session_builder(
        config=@client.SessionBuilder::new(
          connection~,
          contact_points=contacts,
          discovery~,
          routing=@client.RoutingConfig::new("dc1", allow_remote=true),
        ),
        fallback => {
          ready(local_session, 3)
          ready(fallback, 3)
          let snapshot = local_session.topology().unwrap()
          assert_eq(
            snapshot.nodes.filter(node => node.data_center == "dc1").length(),
            1,
          )
          assert_eq(
            snapshot.nodes.filter(node => node.data_center == "dc2").length(),
            2,
          )
          assert_eq(local_session.query_plan().length(), 1)
          assert_eq(local_session.query_plan()[0].port, ports[0])
          ignore(
            local_session.query(
              "CREATE KEYSPACE IF NOT EXISTS mooncql_multidc WITH replication = {'class':'NetworkTopologyStrategy','dc1':1,'dc2':1}",
            ),
          )
          ignore(
            local_session.query(
              "ALTER KEYSPACE mooncql_multidc WITH replication = {'class':'NetworkTopologyStrategy','dc1':1,'dc2':2}",
            ),
          )
          ignore(
            local_session.query(
              "CREATE TABLE IF NOT EXISTS mooncql_multidc.probe (id int PRIMARY KEY,value text)",
            ),
          )
          @async.with_timeout(60000, () => {
            while true {
              let all_updated = [local_session, fallback].all(session => {
                session.topology() is Some(snapshot) &&
                !session.control_status().unwrap().stale &&
                snapshot.keyspaces.get("mooncql_multidc")
                is Some(@routing.Replication::NetworkTopology(factors)) &&
                factors.get("dc1") == Some(1) &&
                factors.get("dc2") == Some(2)
              })
              if all_updated &&
                local_session.check_schema_agreement().state == Agreed {
                break
              }
              @async.sleep(50)
            }
          })
          replicas(local_session, directory)
          let options = @protocol.QueryOptions::new(consistency=LocalQuorum)
          ignore(
            local_session.query(
              "INSERT INTO mooncql_multidc.probe (id,value) VALUES (0,'local')",
              options~,
            ),
          )
          @fs.write_file("\{directory}/ready", b"ready\n")
          marker(directory, "down")
          ready(local_session, 2)
          ready(fallback, 2)
          assert_eq(local_session.query_plan().length(), 0)
          assert_true(
            try {
              ignore(
                local_session.query(
                  "SELECT value FROM mooncql_multidc.probe WHERE id=0",
                  options~,
                  deadline=@client.Deadline::after(300),
                ),
              )
              false
            } catch {
              @client.TimedOut(info) =>
                !info.may_have_been_sent && info.phase == WaitingConnection
              _ => false
            },
          )
          guard fallback.query("SELECT data_center FROM system.local", options~)
            is Rows(remote) else {
            fail("missing remote coordinator")
          }
          assert_eq(remote.get(0, "data_center"), @types.Value::Text("dc2"))
          // 每次业务操作只执行一次；未知写入结果不由验收脚本重放。
          ignore(
            fallback.query(
              "INSERT INTO mooncql_multidc.probe (id,value) VALUES (1,'remote')",
              options~,
            ),
          )
          guard fallback.query(
              "SELECT value FROM mooncql_multidc.probe WHERE id=1",
              options~,
            )
            is Rows(page) else {
            fail("remote LOCAL_QUORUM failed")
          }
          assert_eq(page.get(0, "value"), @types.Value::Text("remote"))
          @fs.write_file("\{directory}/isolated", b"isolated\n")
          marker(directory, "up")
          ready(local_session, 3)
          ready(fallback, 3)
          assert_eq(local_session.query_plan().length(), 1)
          assert_eq(fallback.query_plan()[0].port, ports[0])
          for session in [local_session, fallback] {
            ignore(session.drain(@client.Deadline::after(5000)))
            assert_eq(session.resources().background_task_handles, 0)
            assert_eq(session.budget().in_flight_bytes, 0L)
            assert_eq(session.budget().waiting, 0)
          }
          @fs.write_file(
            "\{directory}/result.json",
            "{\"passed\":true,\"data_centers\":2,\"nodes\":3,\"replica_checks\":64,\"remote_fallback\":true,\"local_quorum_preserved\":true,\"resources\":0}\n",
          )
          println(
            "PASS two DCs, RF change, 64 replica sets, local isolation and explicit remote LOCAL_QUORUM, resources=0",
          )
        },
      )
    },
  )
}

///|
async fn main {
  run() catch {
    @client.Server(server) =>
      fail("Cassandra \{server.code}: \{server.message}")
    @client.Unexpected(message) | @client.Configuration(message) =>
      fail(message)
    error => raise error
  }
}
