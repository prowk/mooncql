///|
async fn main {
  let provider = match
    (@env.get_env_var("CQL_USERNAME"), @env.get_env_var("CQL_PASSWORD")) {
    (Some(username), Some(password)) =>
      Some(@client.AuthProvider::password(_ => (username, password)))
    (None, None) => None
    _ => fail("set both CQL_USERNAME and CQL_PASSWORD")
  }
  let config = @client.Config::new(
    host=@env.get_env_var("CQL_HOST").unwrap_or("127.0.0.1"),
    port=@string.parse_int(@env.get_env_var("CQL_PORT").unwrap_or("9042")),
    auth_provider?=provider,
    compression=@env.get_env_var("CQL_COMPRESSION") == Some("lz4"),
  )
  @client.with_session(
    config=@client.SessionConfig::new(
      connection=config,
      connections_per_node=@string.parse_int(
        @env.get_env_var("CQL_POOL_SIZE").unwrap_or("1"),
      ),
      schema_agreement=@client.SchemaAgreementConfig::new(wait_after_ddl=true),
    ),
    session => {
      ignore(
        session.query(
          "CREATE KEYSPACE IF NOT EXISTS mooncql_examples WITH replication={'class':'SimpleStrategy','replication_factor':1}",
        ),
      )
      ignore(
        session.query(
          "CREATE TABLE IF NOT EXISTS mooncql_examples.features(device int,id int,message text,PRIMARY KEY(device,id))",
        ),
      )
      let insert = session.prepare(
        "INSERT INTO features(device,id,message) VALUES(?,?,?)",
        keyspace="mooncql_examples",
      )
      let batch = [
        insert.bind_batch([Integer(42), Integer(1), Text("逻辑预处理")]),
        @client.SessionBatchStatement::query(
          "INSERT INTO features(device,id,message) VALUES(?,?,?)",
          values=[Integer(42), Integer(2), Text("普通语句")],
        ),
      ]
      let execution = session.batch_with_info(
        batch,
        kind=Unlogged,
        options=@protocol.QueryOptions::new(keyspace="mooncql_examples"),
      )
      let pages = session.pages(
        "SELECT id,message FROM mooncql_examples.features WHERE device=?",
        values=[Integer(42)],
        options=@protocol.QueryOptions::new(page_size=1),
      )
      let mut count = 0
      while pages.next() is Some(page) {
        for row in 0..<page.rows.length() {
          assert_eq(page.get(row, "id"), @types.Value::Integer(count + 1))
          count += 1
        }
      }
      assert_eq(count, 2)
      assert_eq(
        session.check_schema_agreement().state,
        @client.SchemaAgreementState::Agreed,
      )
      assert_eq(
        session.drain(@client.Deadline::after(2000)),
        @client.DrainOutcome::Drained,
      )
      assert_eq(session.resources().background_task_handles, 0)
      println(
        "PASS development features rows=\{count} batch_attempts=\{execution.info.attempt_count} resources=0",
      )
    },
  )
}
