///|
fn tracing_id(info : @client.ExecutionInfo) -> Bytes raise {
  guard info.tracing_id is Some(id) && id.length() == 16 else {
    fail("missing tracing UUID")
  }
  // 默认 QueryHandler 不回显 custom payload；空返回不代表发送失败。
  assert_true(info.custom_payload.is_empty())
  id
}

///|
async fn verify_execution(connection : @client.Connection) -> Unit {
  ignore(
    connection.query(
      "CREATE TABLE IF NOT EXISTS mooncql_test.trace_probe (id int PRIMARY KEY,value text)",
    ),
  )
  ignore(connection.query("TRUNCATE mooncql_test.trace_probe"))
  let request_options = @protocol.RequestOptions::new(
    tracing=true,
    custom_payload=Map([("mooncql-test", Some(b"payload"))]),
  )
  let options = @protocol.QueryOptions::new(request_options~)
  let query = connection.query_with_info(
    "SELECT release_version FROM system.local",
    options~,
  )
  let ids = [tracing_id(query.info)]
  assert_eq(query.info.attempt_count, 1)
  let prepared = connection.prepare_with_info(
    "SELECT value FROM mooncql_test.trace_probe WHERE id=?",
    request_options~,
  )
  ids.push(tracing_id(prepared.info))
  let batch = connection.batch_with_info(
    [
      Query(
        "INSERT INTO mooncql_test.trace_probe (id,value) VALUES (1,'one')",
        [],
      ),
      Query(
        "INSERT INTO mooncql_test.trace_probe (id,value) VALUES (2,'two')",
        [],
      ),
      Query(
        "INSERT INTO mooncql_test.trace_probe (id,value) VALUES (3,'three')",
        [],
      ),
    ],
    options~,
  )
  if batch.info.tracing_id is Some(id) {
    ids.push(id)
  }
  assert_true(batch.info.custom_payload.is_empty())
  let result = prepared.value.execute_with_info([Integer(1)], options~)
  ids.push(tracing_id(result.info))
  guard result.value is Rows(page) else { fail("missing traced prepared row") }
  assert_eq(page.get(0, "value"), @types.Value::Text("one"))
  let pages = connection.pages(
    "SELECT id,value FROM mooncql_test.trace_probe",
    options=@protocol.QueryOptions::new(page_size=1, request_options~),
  )
  let mut rows = 0
  while pages.next_with_info() is Some(page) {
    rows += page.value.rows.length()
    ids.push(tracing_id(page.info))
  }
  assert_eq(rows, 3)
  for id in ids {
    @async.with_timeout(10000, () => {
      while true {
        guard connection.query(
            "SELECT session_id FROM system_traces.sessions WHERE session_id=?",
            values=[Uuid(id)],
          )
          is Rows(sessions) else {
          fail("missing trace sessions result")
        }
        if !sessions.rows.is_empty() {
          assert_eq(sessions.get(0, "session_id"), @types.Value::Uuid(id))
          break
        }
        @async.sleep(50)
      }
    })
  }
  println(
    "PASS tracing QUERY/PREPARE/EXECUTE/pages, batch execution info, ignored custom payload and queryable trace UUIDs=\{ids.length()}",
  )
}
