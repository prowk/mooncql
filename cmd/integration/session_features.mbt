///|
async fn verify_session_batches(config : @client.Config) -> Unit {
  let provider = match (config.username, config.password) {
    (Some(username), Some(password)) =>
      Some(@client.AuthProvider::password(_ => (username, password)))
    _ => None
  }
  @client.with_session(
    config=@client.SessionConfig::new(connection={
      ..config,
      username: None,
      password: None,
      auth_provider: provider,
    }),
    session => {
      ignore(
        session.query(
          "CREATE TABLE IF NOT EXISTS mooncql_test.session_batches(device int,id int,value text,PRIMARY KEY(device,id))",
        ),
      )
      ignore(session.query("TRUNCATE mooncql_test.session_batches"))
      let insert = session.prepare(
        "INSERT INTO session_batches(device,id,value) VALUES(?,?,?)",
        keyspace="mooncql_test",
      )
      for (kind, id) in [(@protocol.BatchType::Logged, 1), (Unlogged, 3)] {
        let batch = [
          insert.bind_batch([Integer(42), Integer(id), Text("prepared")]),
          @client.SessionBatchStatement::query(
            "INSERT INTO session_batches(device,id,value) VALUES(?,?,?)",
            values=[Integer(42), Integer(id + 1), Text("plain")],
          ),
        ]
        let execution = session.batch_with_info(
          batch,
          kind~,
          options=@protocol.QueryOptions::new(keyspace="mooncql_test"),
        )
        assert_eq(execution.info.attempt_count, 1)
        assert_eq(execution.info.coordinator.port, config.port)
      }
      guard session.query(
          "SELECT id,value FROM mooncql_test.session_batches WHERE device=42",
        )
        is Rows(page) else {
        fail("missing session batch rows")
      }
      assert_eq(page.rows.length(), 4)
      for row in 0..<4 {
        assert_eq(page.get(row, "id"), @types.Value::Integer(row + 1))
        assert_eq(
          page.get(row, "value"),
          @types.Value::Text(if row % 2 == 0 { "prepared" } else { "plain" }),
        )
      }
      ignore(
        session.query(
          "CREATE TABLE IF NOT EXISTS mooncql_test.session_counters(id int PRIMARY KEY,n counter)",
        ),
      )
      ignore(session.query("TRUNCATE mooncql_test.session_counters"))
      let counter = session.prepare(
        "UPDATE mooncql_test.session_counters SET n=n+? WHERE id=?",
      )
      session.batch(
        [
          counter.bind_batch([BigInteger(2L), Integer(1)]),
          @client.SessionBatchStatement::query(
            "UPDATE mooncql_test.session_counters SET n=n+? WHERE id=?",
            values=[BigInteger(3L), Integer(1)],
          ),
        ],
        kind=Counter,
      )
      guard session.query(
          "SELECT n FROM mooncql_test.session_counters WHERE id=1",
        )
        is Rows(page) else {
        fail("missing session counter row")
      }
      assert_eq(page.get(0, "n"), @types.Value::BigInteger(5L))
      assert_eq(
        session.drain(@client.Deadline::after(2000)),
        @client.DrainOutcome::Drained,
      )
      assert_eq(session.resources().active, 0)
      assert_eq(session.resources().background_task_handles, 0)
      assert_eq(session.resources().in_flight_bytes, 0L)
    },
  )
  println(
    "PASS Session mixed batches logged unlogged counter dynamic PasswordAuthenticator and graceful drain",
  )
}
