///|
async fn main {
  let count = @string.parse_int(
    @env.get_env_var("CQL_EXAMPLE_ROWS").unwrap_or("64"),
  )
  let device = @string.parse_int(@env.get_env_var("CQL_DEVICE").unwrap_or("42"))
  let message = @env.get_env_var("CQL_MESSAGE").unwrap_or("设备事件")
  if count < 1 || count > 10000 {
    fail("CQL_EXAMPLE_ROWS must be 1..10000")
  }
  @client.with_connection(
    config=@client.Config::new(
      host=@env.get_env_var("CQL_HOST").unwrap_or("127.0.0.1"),
      port=@string.parse_int(@env.get_env_var("CQL_PORT").unwrap_or("9042")),
      username?=@env.get_env_var("CQL_USERNAME"),
      password?=@env.get_env_var("CQL_PASSWORD"),
      compression=@env.get_env_var("CQL_COMPRESSION") == Some("lz4"),
    ),
    connection => {
      ignore(
        connection.query(
          "CREATE KEYSPACE IF NOT EXISTS mooncql_examples WITH replication={'class':'SimpleStrategy','replication_factor':1}",
        ),
      )
      ignore(
        connection.query(
          "CREATE TABLE IF NOT EXISTS mooncql_examples.events(device int,id int,message text,large_value bigint,recorded_at timestamp,tags list<text>,PRIMARY KEY(device,id))",
        ),
      )
      // 仅清理本示例的指定设备分区，不截断其他设备的数据。
      ignore(
        connection.query("DELETE FROM mooncql_examples.events WHERE device=?", values=[
          Integer(device),
        ]),
      )
      let insert = connection.prepare(
        "INSERT INTO mooncql_examples.events(device,id,message,large_value,recorded_at,tags) VALUES(?,?,?,?,?,?)",
      )
      let writes : Array[async () -> Unit] = Array::makei(count, id => {
        () => {
          ignore(
            insert.execute([
              Integer(device),
              Integer(id),
              Text("\{message} \{id}"),
              BigInteger(9007199254740993L + id.to_int64()),
              Timestamp(1700000000000L + id.to_int64()),
              ListValue([Text("中文"), Text("moon")]),
            ]),
          )
        }
      })
      ignore(@async.all(writes, max_concurrent=16))
      let select = connection.prepare(
        "SELECT id,message,large_value,recorded_at,tags FROM mooncql_examples.events WHERE device=?",
      )
      let pager = select.pages(
        [Integer(device)],
        options=@protocol.QueryOptions::new(page_size=17, skip_metadata=true),
      )
      let mut seen = 0
      let mut pages = 0
      let mut checksum = 0L
      while pager.next() is Some(page) {
        pages += 1
        for row in 0..<page.rows.length() {
          assert_eq(page.get(row, "id"), @types.Value::Integer(seen))
          assert_eq(
            page.get(row, "message"),
            @types.Value::Text("\{message} \{seen}"),
          )
          assert_eq(
            page.get(row, "large_value"),
            @types.Value::BigInteger(9007199254740993L + seen.to_int64()),
          )
          assert_eq(
            page.get(row, "recorded_at"),
            @types.Value::Timestamp(1700000000000L + seen.to_int64()),
          )
          assert_eq(
            page.get(row, "tags"),
            @types.Value::ListValue([Text("中文"), Text("moon")]),
          )
          checksum += seen.to_int64()
          seen += 1
        }
      }
      assert_eq(seen, count)
      assert_eq(checksum, count.to_int64() * (count - 1).to_int64() / 2L)
      if @env.get_env_var("CQL_EXAMPLE_ERROR") == Some("1") {
        assert_true(
          try {
            ignore(
              connection.query(
                "SELECT missing FROM mooncql_examples.events WHERE device=?",
                values=[Integer(device)],
              ),
            )
            false
          } catch {
            @client.Server(error) => error.code == 0x2200
            _ => false
          },
        )
        assert_true(!connection.is_closed())
        println("PASS expected_error=invalid_column connection_usable=true")
      }
      println(
        "PASS scenario=device-events rows=\{seen} pages=\{pages} checksum=\{checksum}",
      )
    },
  )
}
