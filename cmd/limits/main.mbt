///|
async fn main {
  let host = @env.get_env_var("CQL_HOST").unwrap_or("127.0.0.1")
  let ports = @env.get_env_var("CQL_CONTACT_PORTS").unwrap_or_else(() => {
    @env.get_env_var("CQL_PORT").unwrap_or("9042")
  })
  let endpoints = []
  for port in ports.split(",") {
    endpoints.push(@client.Endpoint::new(host~, port=@string.parse_int(port)))
  }
  let metrics = @client.Metrics::new()
  let pool_size = @string.parse_int(
    @env.get_env_var("CQL_POOL_SIZE").unwrap_or("1"),
  )
  @client.with_session(
    config=@client.SessionConfig::new(
      connection=@client.Config::new(
        host~,
        username?=@env.get_env_var("CQL_USERNAME"),
        password?=@env.get_env_var("CQL_PASSWORD"),
        compression=@env.get_env_var("CQL_COMPRESSION") == Some("lz4"),
        max_in_flight=1,
        heartbeat_interval_ms=0,
        metrics~,
      ),
      contact_points=endpoints,
      connections_per_node=pool_size,
      limits=@client.SessionLimits::new(
        max_in_flight=2,
        max_in_flight_bytes=4096,
        max_waiting=12,
        max_waiting_bytes=32768,
      ),
    ),
    session => {
      @async.with_timeout(30000, () => {
        while !session.pools().all(pool => pool.ready == pool_size) {
          @async.sleep(10)
        }
      })
      @async.with_task_group(reads => {
        let tasks = []
        for _ in 0..<12 {
          tasks.push(
            reads.spawn(() => {
              guard session.query("SELECT cluster_name FROM system.local")
                is Rows(page) else {
                fail("missing cluster identity")
              }
              assert_eq(page.rows.length(), 1)
              assert_true(!page.row(0).text("cluster_name").is_empty())
            }),
          )
        }
        for task in tasks {
          task.wait()
        }
      })
      let observed = metrics.snapshot()
      assert_true(observed.peak_in_flight <= 2L)
      assert_true(observed.peak_in_flight_bytes <= 4096L)
      assert_true(observed.peak_waiting <= 12L)
      assert_true(observed.peak_waiting_bytes <= 32768L)
      assert_eq(
        session.drain(@client.Deadline::after(2000)),
        @client.DrainOutcome::Drained,
      )
      let budget = session.budget()
      assert_eq(budget.in_flight, 0)
      assert_eq(budget.in_flight_bytes, 0L)
      assert_eq(budget.waiting, 0)
      assert_eq(budget.waiting_bytes, 0L)
      assert_eq(session.resources().background_task_handles, 0)
      println(
        "PASS Session total budget requests=12 peak_rpc=\{observed.peak_in_flight} capacity=2 nodes=\{endpoints.length()} pool_size=\{pool_size} resources=0",
      )
    },
  )
}
