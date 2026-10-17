///|
/// 驱动命令行入口，后续添加真实数据库示例。
async fn main {
  @client.with_connection(config=@client.Config::new(port=19042), connection => {
    let result = connection.query(
      "SELECT cluster_name, release_version FROM system.local",
    )
    println(@debug.to_string(result))
  })
}
