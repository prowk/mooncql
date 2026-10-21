///|
async fn verify_connection_health(config : @client.Config) -> Unit {
  let probes = [0]
  let metrics = @client.Metrics::new(listener=event => {
    if event is RequestFinished(request) &&
      request.opcode == 5 &&
      request.outcome is Succeeded {
      probes[0] += 1
    }
  })
  @client.with_session(
    config=@client.SessionConfig::new(connection={
      ..config,
      heartbeat_interval_ms: 50,
      heartbeat_timeout_ms: 2000,
      metrics: Some(metrics),
    }),
    session => {
      ignore(session.query("SELECT release_version FROM system.local"))
      @async.with_timeout(5000, () => {
        while probes[0] == 0 {
          @async.sleep(10)
        }
      })
      assert_true(
        session.query("SELECT release_version FROM system.local") is Rows(_),
      )
      session.close()
      assert_eq(session.resources().pending, 0)
      assert_eq(session.resources().background_task_handles, 0)
      assert_eq(session.resources().in_flight_bytes, 0L)
    },
  )
  println("PASS real idle OPTIONS heartbeat and joined Session shutdown")
}

///|
async fn verify_signed_timestamp(connection : @client.Connection) -> Unit {
  ignore(
    connection.query(
      "CREATE TABLE IF NOT EXISTS mooncql_test.timestamp_probe (id int PRIMARY KEY, value text)",
    ),
  )
  ignore(connection.query("TRUNCATE mooncql_test.timestamp_probe"))
  ignore(
    connection.query(
      "INSERT INTO mooncql_test.timestamp_probe (id,value) VALUES (1,'before epoch')",
      options=@protocol.QueryOptions::new(timestamp=-1L),
    ),
  )
  guard connection.query(
      "SELECT writetime(value) AS ts FROM mooncql_test.timestamp_probe WHERE id=1",
    )
    is Rows(page) else {
    fail("missing timestamp probe")
  }
  assert_eq(page.get(0, "ts"), @types.Value::BigInteger(-1L))
  println("PASS real signed default write timestamp")
}
