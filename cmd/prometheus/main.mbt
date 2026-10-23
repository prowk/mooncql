///|
async fn main {
  let meter = Meter::new()
  let metrics = @client.Metrics::new(listener=event => meter.observe(event))
  let connection = @client.Config::new(
    host=@env.get_env_var("CQL_HOST").unwrap_or("127.0.0.1"),
    port=@env.get_env_var("CQL_PORT")
      .map(port => @string.parse_int(port))
      .unwrap_or(9042),
    username?=@env.get_env_var("CQL_USERNAME"),
    password?=@env.get_env_var("CQL_PASSWORD"),
    compression=@env.get_env_var("CQL_COMPRESSION") == Some("lz4"),
    metrics~,
    heartbeat_interval_ms=200,
    heartbeat_timeout_ms=1000,
    tls?=if @env.get_env_var("CQL_TLS") == Some("1") {
      Some(
        @client.TlsConfig::new(
          ca_file?=@env.get_env_var("CQL_TLS_CA"),
          server_name?=@env.get_env_var("CQL_TLS_NAME"),
        ),
      )
    } else {
      None
    },
  )
  @client.with_session(config=@client.SessionConfig::new(connection~), session => {
    let failure = try {
      let prepared = session.prepare("SELECT release_version FROM system.local")
      for _ in 0..<3 {
        guard prepared.execute([]) is Rows(page) &&
          page.get(0, "release_version") is Text(version) &&
          !version.is_empty() else {
          fail("expected server version row")
        }
      }
      @async.with_timeout(3000, () => {
        while !meter.nodes
              .values()
              .to_array()
              .any(node => node.queue[2].count > 0L) {
          @async.sleep(10)
        }
      })
      None
    } catch {
      error => Some(error)
    }
    // 示例输出可直接提供给 textfile collector，状态在排空后读取。
    ignore(session.drain(@client.Deadline::after(5000)))
    assert_eq(session.resources().background_task_handles, 0)
    let text = meter.text(session)
    match @env.get_env_var("CQL_METRICS_FILE") {
      Some(path) => @fs.write_file(path, text)
      None => println(text)
    }
    if failure is Some(_) {
      fail(
        "request failed; inspect diagnostic metrics and connection configuration",
      )
    }
  })
}
