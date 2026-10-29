///|
test "0.2.0 ExecutionInfo and Execution complete record construction remains unchanged" {
  let info : @client.ExecutionInfo = {
    coordinator: @client.Endpoint::new(),
    attempt_count: 1,
    warnings: [],
    tracing_id: None,
    custom_payload: Map([]),
    previous: [],
    cached: false,
  }
  let execution : @client.Execution[Int32] = { value: 42, info, }
  assert_eq(execution.value, 42)
  assert_eq(execution.info.attempt_count, 1)
}
