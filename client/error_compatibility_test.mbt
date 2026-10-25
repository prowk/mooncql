///|
fn legacy_drivererror(value : @client.DriverError) -> Unit {
  match value {
    @client.Closed => ()
    @client.Unexpected(_) => ()
    @client.Authentication(_) => ()
    @client.TlsFailure(_) => ()
    @client.Server(_) => ()
    @client.TimedOut(_) => ()
    @client.Configuration(_) => ()
    @client.Overloaded(_) => ()
    @client.AbandonedLimitExceeded => ()
    @client.AbandonedRequestExpired => ()
    @client.HeartbeatFailed => ()
  }
}

///|
fn legacy_timeoutphase(value : @client.TimeoutPhase) -> Unit {
  match value {
    @client.Connecting => ()
    @client.WaitingSlot => ()
    @client.WaitingWriteLock => ()
    @client.Sending => ()
    @client.WaitingResponse => ()
    @client.WaitingPrepare => ()
    @client.WaitingConnection => ()
    @client.WaitingRetry => ()
  }
}

///|
fn legacy_overloadreason(value : @client.OverloadReason) -> Unit {
  match value {
    @client.InFlightLimit => ()
    @client.ByteLimit => ()
    @client.WaitingQueueFull => ()
    @client.WaitingBytesFull => ()
    @client.RequestTooLarge => ()
  }
}

///|
test "0.2.0 DriverError TimeoutPhase and OverloadReason exhaustive matches stay compatible" {
  legacy_drivererror(@client.Closed)
  legacy_timeoutphase(@client.WaitingResponse)
  legacy_overloadreason(@client.RequestTooLarge)
}
