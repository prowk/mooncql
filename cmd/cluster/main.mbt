///|
async fn wait_marker(directory : String, marker : String) -> Unit {
  @async.with_timeout(180000, () => {
    while !@fs.exists("\{directory}/\{marker}") {
      @async.sleep(25)
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
  })
}

///|
async fn wait_schema(session : @client.Session) -> Unit {
  let agreement = session.wait_schema_agreement(
    deadline=@client.Deadline::after(30000),
  )
  assert_eq(agreement.state, @client.SchemaAgreementState::Agreed)
  assert_eq(agreement.observations.length(), 3)
  assert_true(!agreement.timed_out)
}

///|
async fn verify_schema_ddl(session : @client.Session) -> Unit {
  ignore(
    session.query("DROP TABLE IF EXISTS mooncql_cluster_probe.schema_udt_probe"),
  )
  ignore(
    session.query("DROP TYPE IF EXISTS mooncql_cluster_probe.schema_address"),
  )
  ignore(
    session.query(
      "CREATE TYPE mooncql_cluster_probe.schema_address(street text)",
    ),
  )
  let changed = session.query_with_schema_info(
    "ALTER TYPE mooncql_cluster_probe.schema_address ADD zip int",
  )
  assert_true(changed.value is SchemaChanged(_))
  guard changed.schema_agreement is Some(report) else {
    fail("missing schema agreement report")
  }
  assert_eq(report.state, @client.SchemaAgreementState::Agreed)
  assert_eq(report.observations.length(), 3)
  ignore(
    session.query(
      "CREATE TABLE mooncql_cluster_probe.schema_udt_probe(id int PRIMARY KEY,address frozen<schema_address>)",
    ),
  )
  let insert = session.prepare(
    "INSERT INTO mooncql_cluster_probe.schema_udt_probe(id,address) VALUES(?,?)",
  )
  ignore(
    insert.execute(
      [
        Integer(1),
        UdtValue([("street", Text("月亮路")), ("zip", Integer(12345))]),
      ],
      options=@protocol.QueryOptions::new(consistency=All),
    ),
  )
  let select = session.prepare(
    "SELECT address FROM mooncql_cluster_probe.schema_udt_probe WHERE id=?",
  )
  guard select.execute(
      [Integer(1)],
      options=@protocol.QueryOptions::new(consistency=All),
    )
    is Rows(page) else {
    fail("missing schema UDT result")
  }
  assert_eq(
    page.get(0, "address"),
    @types.Value::UdtValue([
      ("street", Text("月亮路")),
      ("zip", Integer(12345)),
    ]),
  )
  println(
    "PASS three-node schema agreement after CREATE and ALTER UDT before prepare",
  )
}

///|
async fn verify_rows(
  statement : @client.SessionPrepared,
  expected : Array[(Int32, Int32)],
) -> Unit {
  let reads = expected.map(pair => {
    () => {
      let (id, value) = pair
      guard statement.execute(
          [Integer(id)],
          options=@protocol.QueryOptions::new(
            consistency=Quorum,
            skip_metadata=true,
          ),
        )
        is Rows(page) else {
        fail("missing quorum row")
      }
      assert_eq(page.rows.length(), 1)
      assert_eq(page.get(0, "value"), @types.Value::Integer(value))
    }
  })
  ignore(@async.all(reads, max_concurrent=16))
}

///|
async fn main {
  guard @env.get_env_var("CQL_CLUSTER_DIR") is Some(directory) else {
    fail("CQL_CLUSTER_DIR required")
  }
  let endpoints = []
  for
    port in @env.get_env_var("CQL_CLUSTER_PORTS")
    .unwrap_or("19052,19053,19054")
    .split(",") {
    endpoints.push(@client.Endpoint::new(port=@string.parse_int(port)))
  }
  assert_eq(endpoints.length(), 3)
  let config = @client.SessionBuilder::new(
    connection=@client.ConnectionBuilder::new(
      username?=@env.get_env_var("CQL_USERNAME"),
      password?=@env.get_env_var("CQL_PASSWORD"),
      compression=@env.get_env_var("CQL_COMPRESSION") == Some("lz4"),
      operation_timeout_ms=180000,
    ),
    contact_points=endpoints,
    schema_agreement=@client.SchemaAgreementConfig::new(
      wait_after_ddl=true,
      timeout_ms=30000,
    ),
  )
  @client.with_session_builder(config~, session => {
    wait_ready(session, 3)
    if @env.get_env_var("CQL_USERNAME") is Some(_) {
      ignore(
        session.query(
          "ALTER KEYSPACE system_auth WITH replication = {'class':'NetworkTopologyStrategy','dc1':3}",
        ),
      )
      wait_schema(session)
    }
    ignore(
      session.query(
        "CREATE KEYSPACE IF NOT EXISTS mooncql_cluster_probe WITH replication = {'class':'NetworkTopologyStrategy','dc1':3}",
      ),
    )
    wait_schema(session)
    ignore(
      session.query(
        "CREATE TABLE IF NOT EXISTS mooncql_cluster_probe.items (id int PRIMARY KEY, value int)",
      ),
    )
    wait_schema(session)
    verify_schema_ddl(session)
    ignore(session.query("TRUNCATE mooncql_cluster_probe.items"))
    let insert = session.prepare(
      "INSERT INTO mooncql_cluster_probe.items (id,value) VALUES (?,?)",
    )
    let select = session.prepare(
      "SELECT value FROM mooncql_cluster_probe.items WHERE id=?",
    )
    let expected = []
    for id in 0..<64 {
      ignore(
        insert.execute(
          [Integer(id), Integer(id * 17)],
          options=@protocol.QueryOptions::new(consistency=All),
        ),
      )
      expected.push((id, id * 17))
    }
    for victim in 0..<3 {
      let generations = session.nodes().map(node => node.status.generation)
      @fs.write_file("\{directory}/ready-\{victim}", b"ready\n")
      wait_marker(directory, "down-\{victim}")
      wait_ready(session, 2)
      assert_true(session.nodes()[victim].status.state != Ready)
      for index in 0..<3 {
        if index != victim {
          assert_eq(
            session.nodes()[index].status.generation,
            generations[index],
          )
        }
      }
      verify_rows(select, expected)
      for offset in 0..<8 {
        let id = 100 + victim * 10 + offset
        ignore(
          insert.execute(
            [Integer(id), Integer(id * 17)],
            options=@protocol.QueryOptions::new(consistency=Quorum),
          ),
        )
        expected.push((id, id * 17))
      }
      verify_rows(select, expected)
      @fs.write_file("\{directory}/checked-\{victim}", b"checked\n")
      wait_marker(directory, "up-\{victim}")
      wait_ready(session, 3)
      assert_true(
        session.nodes()[victim].status.generation > generations[victim],
      )
      for index in 0..<3 {
        if index != victim {
          assert_eq(
            session.nodes()[index].status.generation,
            generations[index],
          )
        }
      }
      println(
        "PASS quorum reads/writes with node \{victim} unavailable and rejoined",
      )
    }
    @fs.write_file("\{directory}/ready-all", b"ready\n")
    wait_marker(directory, "down-all")
    wait_ready(session, 0)
    assert_true(
      try {
        ignore(
          select.execute([Integer(0)], deadline=@client.Deadline::after(300)),
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
    @fs.write_file(
      "\{directory}/result.json",
      "{\"cycles\":3,\"rows\":\{expected.length()},\"active\":0,\"waiting\":0}\n",
    )
    println("PASS all nodes unavailable deadline and session shutdown")
  })
}
