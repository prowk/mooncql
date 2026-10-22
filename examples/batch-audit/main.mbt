///|
async fn main {
  let count = @string.parse_int(
    @env.get_env_var("CQL_EXAMPLE_ROWS").unwrap_or("64"),
  )
  let partition = @string.parse_int(
    @env.get_env_var("CQL_DEVICE").unwrap_or("42"),
  )
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
          "CREATE TABLE IF NOT EXISTS mooncql_examples.batch_items(partition int,id int,message text,PRIMARY KEY(partition,id))",
        ),
      )
      let insert = connection.prepare(
        "INSERT INTO mooncql_examples.batch_items(partition,id,message) VALUES(?,?,?)",
      )
      for
        (kind, name) in [
          (@protocol.BatchType::Logged, "logged"),
          (Unlogged, "unlogged"),
        ] {
        ignore(
          connection.query(
            "DELETE FROM mooncql_examples.batch_items WHERE partition=?",
            values=[Integer(partition)],
          ),
        )
        let mut offset = 0
        while offset < count {
          let statements = []
          // 每批至多十条，所有语句保持同一分区；BATCH 不作为跨分区吞吐工具。
          for
            id in offset..<(if offset + 10 < count {
              offset + 10
            } else {
              count
            }) {
            let values : Array[@types.Value] = [
              Integer(partition),
              Integer(id),
              Text("batch \{id}"),
            ]
            statements.push(
              if id % 2 == 0 {
                insert.bind_batch(values)
              } else {
                Query(
                  "INSERT INTO mooncql_examples.batch_items(partition,id,message) VALUES(?,?,?)",
                  values,
                )
              },
            )
          }
          connection.batch(statements, kind~)
          offset += statements.length()
        }
        let pager = connection.pages(
          "SELECT id,message FROM mooncql_examples.batch_items WHERE partition=?",
          values=[Integer(partition)],
          options=@protocol.QueryOptions::new(page_size=17),
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
              @types.Value::Text("batch \{seen}"),
            )
            checksum += seen.to_int64()
            seen += 1
          }
        }
        assert_eq(seen, count)
        assert_eq(checksum, count.to_int64() * (count - 1).to_int64() / 2L)
        println(
          "PASS scenario=batch-audit kind=\{name} rows=\{seen} pages=\{pages} checksum=\{checksum}",
        )
      }
      if @env.get_env_var("CQL_EXAMPLE_ERROR") == Some("1") {
        // 已过期的预处理 ID 交给调用方处理，不能自动重放整批操作。
        assert_true(
          try {
            connection.batch([Prepared(b"invalid-example-id", [])])
            false
          } catch {
            @client.Server(error) => error.code == 0x2500
            _ => false
          },
        )
        assert_true(!connection.is_closed())
        println("PASS expected_error=unprepared_batch replay=false")
      }
    },
  )
}
