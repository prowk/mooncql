///|
async fn verify_v5(connection : @client.Connection) -> Unit {
  let keyspace = "mooncql_test"
  ignore(
    connection.query(
      "CREATE TABLE IF NOT EXISTS mooncql_test.v5_values (id int PRIMARY KEY, d duration, payload blob)",
    ),
  )
  ignore(connection.query("TRUNCATE mooncql_test.v5_values"))
  let payload = Bytes::from_array(
    Array::makei(400000, i => (i % 251).to_byte()),
  )
  ignore(
    connection.query(
      "INSERT INTO v5_values (id,d,payload) VALUES (:id,:d,:payload)",
      values=[Integer(1), Duration(64, 128, 8192L), Bytes(payload)],
      options=@protocol.QueryOptions::new(keyspace~, value_names=[
        "id", "d", "payload",
      ]),
    ),
  )
  let select = connection.prepare(
    "SELECT d,payload FROM v5_values WHERE id=?",
    keyspace~,
  )
  guard select.execute(
      [Integer(1)],
      options=@protocol.QueryOptions::new(skip_metadata=true),
    )
    is Rows(page) else {
    fail("missing large row")
  }
  assert_eq(page.get(0, "d"), @types.Value::Duration(64, 128, 8192L))
  assert_eq(page.get(0, "payload"), @types.Value::Bytes(payload))
  let insert = connection.prepare(
    "INSERT INTO v5_values (id,d) VALUES (?,?)",
    keyspace~,
  )
  connection.batch(
    [
      Query("INSERT INTO v5_values (id,d) VALUES (?,?)", [
        Integer(2),
        Duration(-1, -2, -3L),
      ]),
      insert.bind_batch([Integer(3), Duration(1, 2, 3L)]),
    ],
    options=@protocol.QueryOptions::new(keyspace~),
  )
  connection.batch(
    [
      Query("UPDATE v5_values SET d=? WHERE id=?", [
        Duration(2, 3, 4L),
        Integer(3),
      ]),
    ],
    kind=Unlogged,
    options=@protocol.QueryOptions::new(
      keyspace~,
      now_in_seconds=2000000000,
      timestamp=2000000000000000L,
    ),
  )
  guard connection.query(
      "SELECT d FROM v5_values WHERE id=?",
      values=[Integer(2)],
      options=@protocol.QueryOptions::new(keyspace~),
    )
    is Rows(batch_row) else {
    fail("missing batch row")
  }
  assert_eq(batch_row.get(0, "d"), @types.Value::Duration(-1, -2, -3L))
  ignore(
    connection.query(
      "CREATE TABLE IF NOT EXISTS mooncql_test.v5_counters (id int PRIMARY KEY, n counter)",
    ),
  )
  ignore(connection.query("TRUNCATE mooncql_test.v5_counters"))
  connection.batch(
    [
      Query("UPDATE v5_counters SET n=n+? WHERE id=?", [
        BigInteger(2L),
        Integer(1),
      ]),
    ],
    kind=Counter,
    options=@protocol.QueryOptions::new(keyspace~),
  )
  guard connection.query(
      "SELECT n FROM v5_counters WHERE id=1",
      options=@protocol.QueryOptions::new(keyspace~),
    )
    is Rows(counter) else {
    fail("missing counter row")
  }
  assert_eq(counter.get(0, "n"), @types.Value::BigInteger(2L))
  ignore(
    connection.query(
      "INSERT INTO v5_values (id,d) VALUES (4,1s) USING TTL 60",
      options=@protocol.QueryOptions::new(keyspace~, now_in_seconds=2000000000),
    ),
  )
  for now in [2000000001, 2000000061] {
    guard connection.query(
        "SELECT d FROM v5_values WHERE id=4",
        options=@protocol.QueryOptions::new(keyspace~, now_in_seconds=now),
      )
      is Rows(ttl) else {
      fail("missing TTL result")
    }
    assert_eq(ttl.rows.length(), if now == 2000000001 { 1 } else { 0 })
  }
  ignore(connection.query("DROP TABLE IF EXISTS mooncql_test.v5_metadata"))
  ignore(
    connection.query(
      "CREATE TABLE mooncql_test.v5_metadata (id int PRIMARY KEY, a int)",
    ),
  )
  ignore(
    connection.query("INSERT INTO mooncql_test.v5_metadata (id,a) VALUES (1,2)"),
  )
  let changed = connection.prepare(
    "SELECT * FROM v5_metadata WHERE id=?",
    keyspace~,
  )
  guard changed.execute(
      [Integer(1)],
      options=@protocol.QueryOptions::new(skip_metadata=true),
    )
    is Rows(before) else {
    fail("missing initial metadata")
  }
  assert_eq(before.columns.length(), 2)
  ignore(connection.query("ALTER TABLE mooncql_test.v5_metadata ADD b text"))
  ignore(
    connection.query(
      "UPDATE mooncql_test.v5_metadata SET b='schema' WHERE id=1",
    ),
  )
  guard changed.execute(
      [Integer(1)],
      options=@protocol.QueryOptions::new(skip_metadata=true),
    )
    is Rows(after) else {
    fail("missing changed metadata")
  }
  assert_eq(after.columns.length(), 3)
  assert_eq(after.get(0, "b"), @types.Value::Text("schema"))
  guard changed.execute(
      [Integer(1)],
      options=@protocol.QueryOptions::new(skip_metadata=true),
    )
    is Rows(cached) else {
    fail("missing cached metadata")
  }
  assert_eq(cached.get(0, "b"), @types.Value::Text("schema"))
  assert_true(cached.new_metadata_id is None)
  guard connection.run(
      @protocol.prepare("SELECT * FROM v5_metadata WHERE id=?", keyspace~),
    )
    is Prepared(metadata) else {
    fail("missing prepared metadata")
  }
  let outdated = metadata.result_metadata_id.to_array()
  outdated[0] = (outdated[0].to_int() ^ 1).to_byte()
  guard connection.run(
      @protocol.execute(
        metadata.id,
        Bytes::from_array(outdated),
        [Integer(1)],
        options=@protocol.QueryOptions::new(skip_metadata=true),
      ),
      cached=metadata.result_columns,
    )
    is Rows(notified) else {
    fail("missing metadata change notification")
  }
  assert_true(notified.new_metadata_id is Some(_))
  assert_eq(notified.get(0, "b"), @types.Value::Text("schema"))
  println(
    "PASS v5 large_payload=400000 duration named_values keyspace batch counter TTL metadata_changed",
  )
}
