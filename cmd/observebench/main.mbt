///|
async fn main {
  let mode = @env.get_env_var("OBSERVE_MODE").unwrap_or("off")
  let count = @string.parse_int(
    @env.get_env_var("OBSERVE_COUNT").unwrap_or("10000"),
  )
  let concurrency = @string.parse_int(
    @env.get_env_var("OBSERVE_CONCURRENCY").unwrap_or("32"),
  )
  if count < 100 || count > 1000000 || concurrency < 1 || concurrency > 128 {
    fail("invalid benchmark size")
  }
  let (config, completed) = benchmark_config(mode)
  @client.with_connection(config~, connection => {
    guard connection.query("SELECT release_version FROM system.local")
      is Rows(version) else {
      fail("missing server version")
    }
    guard version.get(0, "release_version") is Text(server_version) else {
      fail("invalid server version")
    }
    let statement = connection.prepare("SELECT key FROM system.local")
    async fn request() -> Unit {
      guard statement.execute([]) is Rows(page) else {
        fail("missing benchmark row")
      }
      assert_eq(page.get(0, "key"), @types.Value::Text("local"))
    }
    for _ in 0..<100 {
      request()
    }
    let requests : Array[async () -> Unit] = Array::makei(count, _ => request)
    let before = completed()
    let started = @async.now()
    ignore(@async.all(requests, max_concurrent=concurrency))
    let elapsed = @async.now() - started
    let delta = completed() - before
    if mode != "off" {
      assert_eq(delta, count.to_int64())
    }
    println(
      "{\"mode\":\"\{mode}\",\"count\":\{count},\"concurrency\":\{concurrency},\"elapsed_ms\":\{elapsed},\"completed_delta\":\{delta},\"server_version\":\"\{server_version}\"}",
    )
  })
}
