///|
async fn main {
  @client.with_connection(
    config=@client.Config::new(
      host=@env.get_env_var("CQL_HOST").unwrap_or("127.0.0.1"),
      port=@string.parse_int(@env.get_env_var("CQL_PORT").unwrap_or("9042")),
      username?=@env.get_env_var("CQL_USERNAME"),
      password?=@env.get_env_var("CQL_PASSWORD"),
      compression=@env.get_env_var("CQL_COMPRESSION") == Some("lz4"),
    ),
    connection => {
      let existing = @env.get_env_var("CQL_INSPECT_EXISTING") == Some("1")
      let payload = Bytes::from_array(
        Array::makei(400000, i => (i % 251).to_byte()),
      )
      if !existing {
        ignore(
          connection.query(
            "CREATE KEYSPACE IF NOT EXISTS mooncql_examples WITH replication={'class':'SimpleStrategy','replication_factor':1}",
          ),
        )
        ignore(
          connection.query(
            "CREATE TYPE IF NOT EXISTS mooncql_examples.inspection_address(street text,zip int)",
          ),
        )
        // 首次演示使用专用表恢复已知 schema，禁止对业务表运行此初始化分支。
        ignore(
          connection.query("DROP TABLE IF EXISTS mooncql_examples.inspection"),
        )
        ignore(
          connection.query(
            "CREATE TABLE mooncql_examples.inspection(id int PRIMARY KEY,payload blob,d duration,pair frozen<tuple<text,int>>,address frozen<inspection_address>)",
          ),
        )
        let insert = connection.prepare(
          "INSERT INTO mooncql_examples.inspection(id,payload,d,pair,address) VALUES(?,?,?,?,?)",
        )
        ignore(
          insert.execute([
            Integer(1),
            Bytes(payload),
            Duration(-1, -2, -3L),
            TupleValue([Text("中文"), Integer(42)]),
            UdtValue([("street", Text("月亮路")), ("zip", Integer(12345))]),
          ]),
        )
      }
      let statement = connection.prepare(
        "SELECT * FROM mooncql_examples.inspection WHERE id=?",
      )
      guard statement.execute(
          [Integer(1)],
          options=@protocol.QueryOptions::new(skip_metadata=true),
        )
        is Rows(before) else {
        fail("missing inspection row")
      }
      assert_eq(before.rows.length(), 1)
      assert_eq(before.get(0, "payload"), @types.Value::Bytes(payload))
      assert_eq(before.get(0, "d"), @types.Value::Duration(-1, -2, -3L))
      assert_eq(
        before.get(0, "pair"),
        @types.Value::TupleValue([Text("中文"), Integer(42)]),
      )
      assert_eq(
        before.get(0, "address"),
        @types.Value::UdtValue([
          ("street", Text("月亮路")),
          ("zip", Integer(12345)),
        ]),
      )
      if !existing {
        ignore(
          connection.query(
            "ALTER TABLE mooncql_examples.inspection ADD note text",
          ),
        )
        ignore(
          connection.query(
            "UPDATE mooncql_examples.inspection SET note='schema updated' WHERE id=1",
          ),
        )
        guard statement.execute(
            [Integer(1)],
            options=@protocol.QueryOptions::new(skip_metadata=true),
          )
          is Rows(after) else {
          fail("missing updated inspection row")
        }
        assert_eq(after.columns.length(), before.columns.length() + 1)
        assert_eq(after.get(0, "note"), @types.Value::Text("schema updated"))
        // 再执行一次省略列定义的响应，验证更新后的元数据已被采用。
        guard statement.execute(
            [Integer(1)],
            options=@protocol.QueryOptions::new(skip_metadata=true),
          )
          is Rows(cached) else {
          fail("missing cached metadata row")
        }
        assert_eq(cached.get(0, "note"), @types.Value::Text("schema updated"))
      }
      if @env.get_env_var("CQL_EXAMPLE_ERROR") == Some("1") {
        assert_true(
          try {
            ignore(
              connection.query(
                "SELECT missing FROM mooncql_examples.inspection WHERE id=1",
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
        "PASS scenario=data-inspector payload=400000 complex_types=true existing=\{existing}",
      )
    },
  )
}
