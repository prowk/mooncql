///|
/// 使用环境变量选择服务端，不打印认证信息。
async fn main {
  let host = @env.get_env_var("CQL_HOST").unwrap_or("127.0.0.1")
  let port = match @env.get_env_var("CQL_PORT") {
    Some(port) => @string.parse_int(port)
    None => 9042
  }
  let config = @client.Config::new(
    host~,
    port~,
    username?=@env.get_env_var("CQL_USERNAME"),
    password?=@env.get_env_var("CQL_PASSWORD"),
  )
  @client.with_connection(config~, connection => {
    let result = connection.query(
      "SELECT cluster_name, release_version FROM system.local",
    )
    println(@debug.to_string(result))
  })
}
