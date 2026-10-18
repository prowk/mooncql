///|
async fn main {
  guard @env.get_env_var("CQL_RECOVERY_DIR") is Some(directory) else {
    fail("CQL_RECOVERY_DIR must name an existing test directory")
  }
  let config = @client.SessionConfig::new(
    connection=@client.Config::new(
      host=@env.get_env_var("CQL_HOST").unwrap_or("127.0.0.1"),
      port=@string.parse_int(@env.get_env_var("CQL_PORT").unwrap_or("9042")),
      username?=@env.get_env_var("CQL_USERNAME"),
      password?=@env.get_env_var("CQL_PASSWORD"),
      compression=@env.get_env_var("CQL_COMPRESSION") == Some("lz4"),
      connect_timeout_ms=2000,
      operation_timeout_ms=120000,
    ),
    backoff_initial_ms=50,
    backoff_max_ms=1000,
  )
  @client.with_session(config~, session => {
    assert_true(
      session.query("SELECT release_version FROM system.local") is Rows(_),
    )
    let prepared = session.prepare(
      "SELECT release_version FROM local",
      keyspace="system",
    )
    let options = @protocol.QueryOptions::new(skip_metadata=true)
    assert_true(prepared.execute([], options~) is Rows(_))
    let probes : Array[(@client.SessionPrepared, Int)] = []
    for
      (keyspace, expected) in [
        ("mooncql_recovery_a", 101),
        ("mooncql_recovery_b", 202),
      ] {
      ignore(
        session.query(
          "CREATE KEYSPACE IF NOT EXISTS \{keyspace} WITH replication = {'class':'SimpleStrategy','replication_factor':1}",
        ),
      )
      ignore(
        session.query(
          "CREATE TABLE IF NOT EXISTS \{keyspace}.probe (id int PRIMARY KEY, value int)",
        ),
      )
      ignore(
        session.query(
          "INSERT INTO \{keyspace}.probe (id,value) VALUES (1,\{expected})",
        ),
      )
      let statement = session.prepare(
        "SELECT value FROM probe WHERE id=?",
        keyspace~,
      )
      verify_probe(statement, expected, options)
      probes.push((statement, expected))
    }
    let initial = session.status().generation
    @fs.write_file("\{directory}/ready", b"ready\n")
    @async.with_timeout(120000, () => {
      while !@fs.exists("\{directory}/go") {
        @async.sleep(25)
      }
      while session.status().generation == initial &&
            session.status().state == Ready {
        @async.sleep(10)
      }
    })
    assert_true(
      session.query("SELECT release_version FROM system.local") is Rows(_),
    )
    assert_true(prepared.execute([], options~) is Rows(_))
    for (statement, expected) in probes {
      verify_probe(statement, expected, options)
    }
    assert_true(session.status().generation > initial)
    let generation = session.status().generation
    let attempts = session.status().attempts
    session.close()
    assert_eq(session.active_count(), 0)
    assert_eq(session.waiting_count(), 0)
    assert_eq(session.status().state, Stopped)
    @fs.write_file(
      "\{directory}/result.json",
      "{\"generation\":\{generation},\"attempts\":\{attempts},\"prepared_reused\":true,\"active\":0,\"waiting\":0}\n",
    )
    println("PASS Session recovered after server restart; all tasks drained")
  })
}

///|
async fn verify_probe(
  statement : @client.SessionPrepared,
  expected : Int,
  options : @protocol.QueryOptions,
) -> Unit {
  guard statement.execute([Integer(1)], options~) is Rows(page) else {
    fail("missing prepared probe row")
  }
  assert_eq(page.get(0, "value"), @types.Value::Integer(expected))
}
