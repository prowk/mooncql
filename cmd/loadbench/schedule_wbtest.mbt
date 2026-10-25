///|
async test "open loop dispatch never precedes its high resolution planned arrival" {
  @async.with_timeout(2000, () => {
    let started = now_ns()
    for index in 0..<20 {
      let planned = index.to_int64() * 250000L
      assert_true(await_arrival(started, planned) >= planned)
    }
  })
}
