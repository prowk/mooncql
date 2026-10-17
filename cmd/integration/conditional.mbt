///|
async fn run_conditional_checks(connection : @client.Connection) -> Unit {
  ignore(
    connection.query(
      "CREATE TABLE IF NOT EXISTS mooncql_test.lwt (id int PRIMARY KEY, value text)",
    ),
  )
  ignore(connection.query("TRUNCATE mooncql_test.lwt"))
  let insert = connection.prepare(
    "INSERT INTO mooncql_test.lwt (id,value) VALUES (?,?) IF NOT EXISTS",
  )
  let update = connection.prepare(
    "UPDATE mooncql_test.lwt SET value=? WHERE id=? IF value=?",
  )
  let ordinary = connection.prepare(
    "SELECT value FROM mooncql_test.lwt WHERE id=?",
  )
  for level in [@protocol.Consistency::Serial, LocalSerial] {
    let key = level.code()
    let options = @protocol.QueryOptions::new(
      skip_metadata=true,
      serial_consistency=level,
    )
    let first = insert.execute_conditional(
      [Integer(key), Text("initial")],
      options~,
    )
    assert_true(first.applied)
    assert_eq(first.page.columns.length(), 1)
    assert_true(first.page.new_metadata_id is None)
    let duplicate = connection.query_conditional(
      "INSERT INTO mooncql_test.lwt (id,value) VALUES (?,?) IF NOT EXISTS",
      values=[Integer(key), Text("discarded")],
      options~,
    )
    assert_true(!duplicate.applied)
    assert_eq(duplicate.page.get(0, "id"), @types.Value::Integer(key))
    assert_eq(duplicate.page.get(0, "value"), @types.Value::Text("initial"))
    for (before, after) in [("initial", "next"), ("next", "final")] {
      let applied = update.execute_conditional(
        [Text(after), Integer(key), Text(before)],
        options~,
      )
      assert_true(applied.applied)
      assert_eq(applied.page.columns.length(), 1)
      assert_true(applied.page.new_metadata_id is None)
      let rejected = update.execute_conditional(
        [Text("discarded"), Integer(key), Text(before)],
        options~,
      )
      assert_true(!rejected.applied)
      assert_eq(rejected.page.get(0, "value"), @types.Value::Text(after))
      assert_true(rejected.page.new_metadata_id is None)
      guard ordinary.execute(
          [Integer(key)],
          options=@protocol.QueryOptions::new(skip_metadata=true),
        )
        is Rows(page) else {
        fail("missing ordinary result")
      }
      assert_eq(page.get(0, "value"), @types.Value::Text(after))
    }
  }
  println(
    "PASS LWT IF_NOT_EXISTS IF_condition applied current_columns skip_metadata SERIAL LOCAL_SERIAL",
  )
}

///|
async fn verify_conditional(connection : @client.Connection) -> Unit {
  run_conditional_checks(connection) catch {
    @codec.CodecError(message) => fail("LWT codec error: " + message)
    error => raise error
  }
}
