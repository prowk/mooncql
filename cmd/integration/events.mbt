///|
async fn expect_schema_event(
  connection : @client.Connection,
  change : @protocol.SchemaChangeKind,
  target : @protocol.SchemaTarget,
) -> Unit {
  @async.with_timeout(10000, () => {
    while true {
      let event = connection.next_event()
      if event is Schema(actual_change, actual_target) &&
        actual_change == change &&
        actual_target == target {
        return
      }
    }
  })
}

///|
async fn verify_events(connection : @client.Connection) -> Unit {
  ignore(
    connection.query(
      "DROP TABLE IF EXISTS mooncql_test.event_subscription_probe",
    ),
  )
  connection.register([TopologyChange, StatusChange, SchemaChange])
  ignore(
    connection.query(
      "CREATE TABLE mooncql_test.event_subscription_probe (id int PRIMARY KEY)",
    ),
  )
  let target = @protocol.SchemaTarget::Table(
    "mooncql_test", "event_subscription_probe",
  )
  expect_schema_event(connection, Created, target)
  ignore(
    connection.query(
      "ALTER TABLE mooncql_test.event_subscription_probe ADD value text",
    ),
  )
  expect_schema_event(connection, Updated, target)
  ignore(connection.query("DROP TABLE mooncql_test.event_subscription_probe"))
  expect_schema_event(connection, Dropped, target)
  assert_eq(connection.dropped_event_count(), 0L)
  println("PASS REGISTER and real CREATED/UPDATED/DROPPED schema events")
}
