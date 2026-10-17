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
    assert_true(session.status().generation > initial)
    let generation = session.status().generation
    let attempts = session.status().attempts
    session.close()
    assert_eq(session.active_count(), 0)
    assert_eq(session.waiting_count(), 0)
    assert_eq(session.status().state, Stopped)
    @fs.write_file(
      "\{directory}/result.json",
      "{\"generation\":\{generation},\"attempts\":\{attempts},\"active\":0,\"waiting\":0}\n",
    )
    println("PASS Session recovered after server restart; all tasks drained")
  })
}
