///|
async fn main {
  guard @env.get_env_var("CQL_RECOVERY_DIR") is Some(directory) else {
    fail("CQL_RECOVERY_DIR must name an existing test directory")
  }
  let config = @client.SessionBuilder::new(
    connection=@client.ConnectionBuilder::new(
      host=@env.get_env_var("CQL_HOST").unwrap_or("127.0.0.1"),
      port=@string.parse_int(@env.get_env_var("CQL_PORT").unwrap_or("9042")),
      username?=@env.get_env_var("CQL_USERNAME"),
      password?=@env.get_env_var("CQL_PASSWORD"),
      compression=@env.get_env_var("CQL_COMPRESSION") == Some("lz4"),
      connect_timeout_ms=2000,
      operation_timeout_ms=120000,
    ),
    backoff_initial_ms=50,
    backoff_max_ms=1000,
  )
  @client.with_session_builder(config~, session => {
    assert_true(
      session.query("SELECT release_version FROM system.local") is Rows(_),
    )
    let prepared = session.prepare(
      "SELECT release_version FROM local",
      keyspace="system",
    )
    let options = @protocol.QueryOptions::new(skip_metadata=true)
    assert_true(prepared.execute([], options~) is Rows(_))
    let probes : Array[(@client.SessionPrepared, Int32)] = []
    for
      (keyspace, expected) in [
        ("mooncql_recovery_a", 101),
        ("mooncql_recovery_b", 202),
      ] {
      ignore(
        session.query(
          "CREATE KEYSPACE IF NOT EXISTS \{keyspace} WITH replication = {'class':'SimpleStrategy','replication_factor':1}",
        ),
      )
      ignore(
        session.query(
          "CREATE TABLE IF NOT EXISTS \{keyspace}.probe (id int PRIMARY KEY, value int)",
        ),
      )
      ignore(
        session.query(
          "INSERT INTO \{keyspace}.probe (id,value) VALUES (1,\{expected})",
        ),
      )
      let statement = session.prepare(
        "SELECT value FROM probe WHERE id=?",
        keyspace~,
      )
      verify_probe(statement, expected, options)
      probes.push((statement, expected))
    }
    let initial = session.status().generation
    ignore(
      session.query(
        "CREATE TABLE IF NOT EXISTS mooncql_recovery_a.page_probe (partition int, id int, PRIMARY KEY (partition,id))",
      ),
    )
    ignore(session.query("TRUNCATE mooncql_recovery_a.page_probe"))
    let insert_page = session.prepare(
      "INSERT INTO mooncql_recovery_a.page_probe (partition,id) VALUES (?,?)",
    )
    for id in 0..<101 {
      ignore(insert_page.execute([Integer(7), Integer(id)]))
    }
    let paging_options = @protocol.QueryOptions::new(
      page_size=17,
      skip_metadata=true,
    )
    let simple_cql = "SELECT id FROM mooncql_recovery_a.page_probe WHERE partition=?"
    let simple_pager = session.pages(
      simple_cql,
      values=[Integer(7)],
      options=paging_options,
    )
    let paging_prepared = session.prepare(
      "SELECT id FROM page_probe WHERE partition=?",
      keyspace="mooncql_recovery_a",
    )
    let prepared_pager = paging_prepared.pages(
      [Integer(7)],
      options=paging_options,
    )
    for pager in [simple_pager, prepared_pager] {
      let page = pager.next().unwrap()
      assert_eq(page.rows.length(), 17)
      for id in 0..<17 {
        assert_eq(page.row(id).int("id"), id)
      }
    }
    let simple_cursor = simple_pager.cursor().to_bytes()
    let prepared_cursor = prepared_pager.cursor().to_bytes()
    @fs.write_file("\{directory}/paging-simple.bin", simple_cursor)
    @fs.write_file("\{directory}/paging-prepared.bin", prepared_cursor)
    assert_true(
      try {
        ignore(
          paging_prepared.pages(
            [Integer(7)],
            options=paging_options,
            cursor=@client.PagingCursor::from_bytes(simple_cursor),
          ),
        )
        false
      } catch {
        @client.Configuration(_) => true
        _ => false
      },
    )
    @fs.write_file("\{directory}/ready", b"ready\n")
    @async.with_timeout(120000, () => {
      while !@fs.exists("\{directory}/go") {
        @async.sleep(25)
      }
      while session.status().generation == initial &&
            session.status().state == Ready {
        @async.sleep(10)
      }
    })
    assert_true(
      session.query("SELECT release_version FROM system.local") is Rows(_),
    )
    assert_true(prepared.execute([], options~) is Rows(_))
    for (statement, expected) in probes {
      verify_probe(statement, expected, options)
    }
    verify_remaining_pages(simple_pager)
    verify_remaining_pages(prepared_pager)
    verify_remaining_pages(
      session.pages(
        simple_cql,
        values=[Integer(7)],
        options=paging_options,
        cursor=@client.PagingCursor::from_bytes(simple_cursor),
      ),
    )
    let replacement_statement = session.prepare(
      "SELECT id FROM page_probe WHERE partition=?",
      keyspace="mooncql_recovery_a",
    )
    verify_remaining_pages(
      replacement_statement.pages(
        [Integer(7)],
        options=paging_options,
        cursor=@client.PagingCursor::from_bytes(prepared_cursor),
      ),
    )
    assert_true(session.status().generation > initial)
    let generation = session.status().generation
    let attempts = session.status().attempts
    session.close()
    assert_eq(session.active_count(), 0)
    assert_eq(session.waiting_count(), 0)
    assert_eq(session.status().state, Stopped)
    @fs.write_file(
      "\{directory}/result.json",
      "{\"generation\":\{generation},\"attempts\":\{attempts},\"prepared_reused\":true,\"paging_rows\":101,\"paging_remaining\":84,\"paging_restores\":4,\"active\":0,\"waiting\":0}\n",
    )
    println("PASS Session recovered after server restart; all tasks drained")
  })
}

///|
async fn verify_remaining_pages(pager : @client.Pager) -> Unit {
  let mut expected = 17
  while pager.next() is Some(page) {
    for index in 0..<page.rows.length() {
      assert_eq(page.row(index).int("id"), expected)
      expected += 1
    }
  }
  assert_eq(expected, 101)
  assert_true(pager.cursor().is_done())
}

///|
async fn verify_probe(
  statement : @client.SessionPrepared,
  expected : Int32,
  options : @protocol.QueryOptions,
) -> Unit {
  guard statement.execute([Integer(1)], options~) is Rows(page) else {
    fail("missing prepared probe row")
  }
  assert_eq(page.get(0, "value"), @types.Value::Integer(expected))
}
