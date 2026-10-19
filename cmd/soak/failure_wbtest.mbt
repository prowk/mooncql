///|
test "smoke counts bounded connection recycling but preserves fatal validation errors" {
  assert_eq(
    transient_reason(@client.AbandonedLimitExceeded),
    Some("abandoned_limit"),
  )
  assert_eq(
    transient_reason(@client.AbandonedRequestExpired),
    Some("abandoned_expired"),
  )
  assert_eq(transient_reason(@client.Closed), Some("disconnected"))
  assert_eq(transient_reason(@client.Unexpected("row mismatch")), None)
  assert_eq(transient_reason(@client.Configuration("bad configuration")), None)
  assert_eq(transient_reason(@client.Authentication("bad credentials")), None)
}

///|
async test "sampling preserves history while replacing only the latest progress" {
  let directory = ".artifacts/soak-log-regression-\{@async.now()}"
  @fs.mkdir(directory, recursive=true, allow_exist=false)
  persist_sample(directory, "{\"sample\":1}")
  persist_sample(directory, "{\"sample\":2}")
  assert_eq(
    @fs.read_file("\{directory}/samples.jsonl").binary(),
    b"{\"sample\":1}\n{\"sample\":2}\n",
  )
  assert_eq(
    @fs.read_file("\{directory}/progress.json").binary(),
    b"{\"sample\":2}",
  )
  @fs.remove("\{directory}/samples.jsonl")
  @fs.remove("\{directory}/progress.json")
}
