///|
test "synchronous listener time is on caller path and diagnostic failures remain bounded" {
  let calls = [0]
  let metrics = Metrics::with_diagnostics(_ => {
    let until = @async.now() + 3L
    while @async.now() < until {
      ()
    }
    calls[0] += 1
  })
  let start = @async.now()
  for _ in 0..<16 {
    metrics.emit_diagnostic(OperationStarted(QueryOperation))
  }
  let elapsed = @async.now() - start
  assert_eq(calls[0], 16)
  assert_true(elapsed >= 47L)
  // 同步监听无队列，阻塞成本直接累加；这里只验证边界，不宣称生产开销。
  println("listener-cost events=16 busy_ms=3 elapsed_ms=\{elapsed}")
}
