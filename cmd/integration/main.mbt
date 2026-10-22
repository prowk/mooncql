///|
fn integer_env(name : String, fallback : Int) -> Int raise {
  match @env.get_env_var(name) {
    Some(value) => @string.parse_int(value)
    None => fallback
  }
}

///|
async fn main {
  let count = integer_env("CQL_ROWS", 10000)
  if count < 1 || count > 100000 {
    fail("CQL_ROWS must be between 1 and 100000")
  }
  let config = @client.Config::new(
    host=@env.get_env_var("CQL_HOST").unwrap_or("127.0.0.1"),
    port=integer_env("CQL_PORT", 9042),
    username?=@env.get_env_var("CQL_USERNAME"),
    password?=@env.get_env_var("CQL_PASSWORD"),
    compression=@env.get_env_var("CQL_COMPRESSION") == Some("lz4"),
    max_in_flight=64,
    throw_on_overload=true,
  )
  let mut report = ""
  let connection = @client.with_connection(config~, connection => {
    guard connection.query("SELECT release_version FROM system.local")
      is Rows(version) else {
      fail("missing server version")
    }
    guard version.get(0, "release_version") is Text(release) else {
      fail("missing version text")
    }
    println("Connected to Cassandra: \{release}")
    let mut authenticator = ""
    let settings = connection.pages(
      "SELECT name,value FROM system_views.settings",
    )
    while settings.next() is Some(page) {
      for row in 0..<page.rows.length() {
        if page.get(row, "name") ==
          @types.Value::Text("authenticator.class_name") ||
          page.get(row, "name") == @types.Value::Text("authenticator") {
          guard page.get(row, "value") is Text(value) else {
            fail("missing authenticator name")
          }
          authenticator = value
        }
      }
    }
    assert_true(authenticator != "")
    guard connection.query(
        "SELECT driver_name,protocol_version FROM system_views.clients",
      )
      is Rows(clients) else {
      fail("missing client protocol view")
    }
    let mut identified = false
    for i = 0; i < clients.rows.length(); i = i + 1 {
      if clients.get(i, "driver_name") == @types.Value::Text("mooncql") {
        assert_eq(clients.get(i, "protocol_version"), @types.Value::Integer(5))
        identified = true
      }
    }
    assert_true(identified)
    ignore(
      connection.query(
        "CREATE KEYSPACE IF NOT EXISTS mooncql_test WITH replication = {'class':'SimpleStrategy','replication_factor':1}",
      ),
    )
    ignore(
      connection.query(
        "CREATE TABLE IF NOT EXISTS mooncql_test.events (device int, id int, large_value bigint, message text, recorded_at timestamp, tags list<text>, attrs map<text,int>, PRIMARY KEY (device,id))",
      ),
    )
    ignore(connection.query("TRUNCATE mooncql_test.events"))
    let insert = connection.prepare(
      "INSERT INTO mooncql_test.events (device,id,large_value,message,recorded_at,tags,attrs) VALUES (?,?,?,?,?,?,?)",
    )
    let started = @async.now()
    let writes : Array[async () -> Unit] = Array::makei(count, id => {
      () => {
        ignore(
          insert.execute([
            Integer(42),
            Integer(id),
            BigInteger(9007199254740993L + id.to_int64()),
            Text("事件 \{id}"),
            Timestamp(1700000000000L + id.to_int64()),
            ListValue([Text("moon"), Text("中文")]),
            MapValue([(Text("index"), Integer(id))]),
          ]),
        )
      }
    })
    ignore(@async.all(writes, max_concurrent=32))
    let write_ms = @async.now() - started
    let pager = connection.pages(
      "SELECT id,large_value,message,recorded_at,tags,attrs FROM mooncql_test.events WHERE device=?",
      values=[Integer(42)],
      options=@protocol.QueryOptions::new(page_size=113),
    )
    let mut seen = 0
    let mut page_count = 0
    let mut simple_checksum = 0L
    let page_sizes : Array[Int] = []
    let terminal_states : Array[Bool] = []
    while pager.next() is Some(page) {
      page_count += 1
      page_sizes.push(page.rows.length())
      terminal_states.push(page.paging_state is None)
      for row = 0; row < page.rows.length(); row = row + 1 {
        let id = seen
        assert_eq(page.get(row, "id"), @types.Value::Integer(id))
        assert_eq(
          page.get(row, "large_value"),
          @types.Value::BigInteger(9007199254740993L + id.to_int64()),
        )
        assert_eq(page.get(row, "message"), @types.Value::Text("事件 \{id}"))
        assert_eq(
          page.get(row, "recorded_at"),
          @types.Value::Timestamp(1700000000000L + id.to_int64()),
        )
        assert_eq(
          page.get(row, "tags"),
          @types.Value::ListValue([Text("moon"), Text("中文")]),
        )
        assert_eq(
          page.get(row, "attrs"),
          @types.Value::MapValue([(Text("index"), Integer(id))]),
        )
        seen += 1
        simple_checksum += id.to_int64()
      }
    }
    assert_eq(seen, count)
    assert_eq(simple_checksum, count.to_int64() * (count - 1).to_int64() / 2L)
    assert_true(terminal_states.last() == Some(true))
    assert_true(pager.next() is None)
    guard connection.query(
        "SELECT id FROM mooncql_test.events WHERE device=42 AND id=0",
        options=@protocol.QueryOptions::new(consistency=Serial),
      )
      is Rows(serial_read) else {
      fail("missing serial read")
    }
    assert_eq(serial_read.get(0, "id"), @types.Value::Integer(0))
    if count > 113 {
      assert_true(page_count > 1)
    }
    let select = connection.prepare(
      "SELECT id FROM mooncql_test.events WHERE device=?",
    )
    let prepared_pages = select.pages(
      [Integer(42)],
      options=@protocol.QueryOptions::new(page_size=127),
    )
    let mut prepared_count = 0
    let mut checksum = 0L
    let mut prepared_page_count = 0
    while prepared_pages.next() is Some(page) {
      prepared_page_count += 1
      for row in page.rows {
        guard row[0] is Integer(id) else { fail("expected integer") }
        assert_eq(id, prepared_count)
        checksum += id.to_int64()
        prepared_count += 1
      }
      if page.paging_state is None {
        assert_eq(prepared_count, count)
      }
    }
    assert_eq(prepared_count, count)
    assert_eq(checksum, count.to_int64() * (count - 1).to_int64() / 2L)
    ignore(
      connection.query(
        "INSERT INTO mooncql_test.events (device,id,message) VALUES (42,-1,'temporary')",
      ),
    )
    ignore(
      connection.query(
        "UPDATE mooncql_test.events SET message=? WHERE device=? AND id=?",
        values=[Text("updated"), Integer(42), Integer(-1)],
      ),
    )
    guard connection.query(
        "SELECT message FROM mooncql_test.events WHERE device=42 AND id=-1",
      )
      is Rows(updated) else {
      fail("missing updated row")
    }
    assert_eq(updated.get(0, "message"), @types.Value::Text("updated"))
    ignore(
      connection.query(
        "DELETE FROM mooncql_test.events WHERE device=42 AND id=-1",
      ),
    )
    guard connection.query(
        "SELECT id FROM mooncql_test.events WHERE device=42 AND id=-1",
      )
      is Rows(deleted) else {
      fail("expected empty rows")
    }
    assert_eq(deleted.rows.length(), 0)
    let server_error = try {
      ignore(
        connection.query(
          "SELECT missing_column FROM mooncql_test.events WHERE device=42",
        ),
      )
      false
    } catch {
      @client.Server(error) => error.code == 0x2200
      _ => false
    }
    assert_true(server_error)
    assert_true(!connection.is_closed())
    verify_v5(connection)
    verify_conditional(connection)
    verify_events(connection)
    verify_topology(config)
    verify_execution(connection)
    verify_connection_health(config)
    verify_signed_timestamp(connection)
    println(
      "PASS rows=\{count} simple_pages=\{page_count} prepared_rows=\{prepared_count} checksum=\{checksum} write_ms=\{write_ms}",
    )
    report = "{\"rows\":\{count},\"checksum\":\{checksum},\"simple_checksum\":\{simple_checksum},\"simple_pages\":\{page_count},\"prepared_pages\":\{prepared_page_count},\"page_size\":113,\"page_sizes\":\{page_sizes.to_json().stringify()},\"terminal_states\":\{terminal_states.to_json().stringify()},\"paging_ended\":true,\"server\":\{release.to_json().stringify()},\"authenticator\":\{authenticator.to_json().stringify()},\"compression\":\{config.compression},\"protocol\":5,\"large_payload_bytes\":400000,\"large_payload_two_way\":true,\"batch\":[\"logged\",\"unlogged\",\"counter\"],\"ttl\":true,\"metadata_updated\":true,\"field_checks\":true,\"write_ms\":\{write_ms}}"
    connection
  })
  assert_true(connection.is_closed())
  assert_eq(connection.pending_count(), 0)
  assert_eq(connection.abandoned_count(), 0)
  assert_eq(connection.in_flight_count(), 0)
  assert_eq(connection.in_flight_bytes(), 0L)
  assert_eq(connection.waiting_count(), 0)
  assert_eq(connection.waiting_bytes(), 0L)
  if @env.get_env_var("CQL_INTEGRATION_REPORT") is Some(path) {
    ignore(@json.parse(report))
    @fs.write_file(path, report + "\n")
  }
}
