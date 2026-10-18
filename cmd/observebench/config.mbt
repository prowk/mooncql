///|
fn benchmark_config(mode : String) -> (@client.Config, () -> Int64) raise {
  let metrics = match mode {
    "off" => None
    "counters" => Some(@client.Metrics::new())
    "listener" => Some(@client.Metrics::new(listener=fn(_event) { () }))
    _ => fail("invalid observation mode")
  }
  let config = @client.Config::new(
    host=@env.get_env_var("CQL_HOST").unwrap_or("127.0.0.1"),
    port=@string.parse_int(@env.get_env_var("CQL_PORT").unwrap_or("9042")),
    username?=@env.get_env_var("CQL_USERNAME"),
    password?=@env.get_env_var("CQL_PASSWORD"),
    compression=@env.get_env_var("CQL_COMPRESSION") == Some("lz4"),
    max_in_flight=128,
    max_waiting=128,
    metrics?,
  )
  (
    config,
    () => {
      match metrics {
        Some(metrics) => metrics.snapshot().requests_succeeded
        None => 0L
      }
    },
  )
}
