///|
async fn main {
  let defaults = @client.ExecutionProfile::new(page_size=2, timeout_ms=5000)
  let reads = @client.ExecutionProfile::new(
    consistency=Quorum,
    page_size=2,
    timeout_ms=5000,
    traversal_timeout_ms=10000,
    retry=@client.RetryPolicy::new(max_attempts=2),
  )
  let connection = @client.Config::new(
    host=@env.get_env_var("CQL_HOST").unwrap_or("127.0.0.1"),
    port=@string.parse_int(@env.get_env_var("CQL_PORT").unwrap_or("9042")),
    username?=@env.get_env_var("CQL_USERNAME"),
    password?=@env.get_env_var("CQL_PASSWORD"),
    compression=@env.get_env_var("CQL_COMPRESSION") == Some("lz4"),
  )
  @client.with_session(
    config=@client.SessionConfig::new(connection~, execution_profile=defaults),
    session => {
      ignore(
        session.query(
          "CREATE KEYSPACE IF NOT EXISTS mooncql_profiles WITH replication={'class':'SimpleStrategy','replication_factor':1}",
        ),
      )
      ignore(
        session.query(
          "CREATE TABLE IF NOT EXISTS mooncql_profiles.items(device int,id int,note text,PRIMARY KEY(device,id))",
        ),
      )
      ignore(
        session.query("DELETE FROM mooncql_profiles.items WHERE device=42"),
      )
      let insert = session.prepare(
        "INSERT INTO mooncql_profiles.items(device,id,note) VALUES(?,?,?)",
      )
      for id in 0..<5 {
        ignore(insert.execute([Integer(42), Integer(id), Text("item-\{id}")]))
      }
      let cql = "SELECT id,note FROM mooncql_profiles.items WHERE device=?"
      let simple = session.pages(cql, values=[Integer(42)], idempotent=true)
      assert_eq(simple.next().unwrap().rows.length(), 2)
      let cursor = @client.PagingCursor::from_bytes(simple.cursor().to_bytes())
      let resumed = session.pages(
        cql,
        values=[Integer(42)],
        cursor~,
        idempotent=true,
      )
      let mut remaining = 0
      while resumed.next() is Some(page) {
        for index in 0..<page.rows.length() {
          assert_eq(page.row(index).int("id"), remaining + 2)
          remaining += 1
        }
      }
      assert_eq(remaining, 3)
      let select = session.prepare(cql, profile=reads)
      let pages = select.pages([Integer(42)], idempotent=true)
      let mut rows = 0
      let mut page_count = 0
      while pages.next() is Some(page) {
        page_count += 1
        for index in 0..<page.rows.length() {
          let row = page.row(index)
          assert_eq(row.int("id"), rows)
          assert_eq(row.text("note"), "item-\{rows}")
          rows += 1
        }
      }
      assert_eq(rows, 5)
      assert_eq(page_count, 3)
      assert_eq(
        session.drain(@client.Deadline::after(2000)),
        @client.DrainOutcome::Drained,
      )
      assert_eq(session.resources().background_task_handles, 0)
      assert_eq(session.resources().in_flight_bytes, 0L)
      println("PASS execution profiles rows=5 prepared_pages=3 resources=0")
    },
  )
}
