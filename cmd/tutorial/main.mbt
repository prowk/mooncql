///|
async fn main {
  let config = @client.Config::new(
    host=@env.get_env_var("CQL_HOST").unwrap_or("127.0.0.1"),
    port=@string.parse_int(@env.get_env_var("CQL_PORT").unwrap_or("9042")),
    username?=@env.get_env_var("CQL_USERNAME"),
    password?=@env.get_env_var("CQL_PASSWORD"),
    compression=@env.get_env_var("CQL_COMPRESSION") == Some("lz4"),
  )
  @client.with_session(config=@client.SessionConfig::new(connection=config), session => {
    // 入门示例使用专用 keyspace；RF=1 仅适合单节点演示。
    ignore(
      session.query(
        "CREATE KEYSPACE IF NOT EXISTS mooncql_tutorial WITH replication = {'class':'SimpleStrategy','replication_factor':1}",
      ),
    )
    ignore(
      session.query(
        "CREATE TABLE IF NOT EXISTS mooncql_tutorial.events (device int, id int, message text, PRIMARY KEY (device,id))",
      ),
    )
    let insert = session.prepare(
      "INSERT INTO events (device,id,message) VALUES (?,?,?)",
      keyspace="mooncql_tutorial",
    )
    for id in 1..<4 {
      ignore(
        insert.execute([
          Integer(42),
          Integer(id),
          Text("来自 MoonBit 的事件"),
        ]),
      )
    }
    let select = session.prepare(
      "SELECT id,message FROM events WHERE device=?",
      keyspace="mooncql_tutorial",
    )
    let pages = select.pages(
      [Integer(42)],
      options=@protocol.QueryOptions::new(page_size=2),
    )
    let mut seen = 0
    while pages.next() is Some(page) {
      for index in 0..<page.rows.length() {
        let row = page.row(index)
        println(row.int("id"))
        println(row.text("message"))
        seen += 1
      }
    }
    assert_eq(seen, 3)
    println("Read 3 events")
  })
}
