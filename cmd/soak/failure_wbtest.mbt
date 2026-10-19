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
