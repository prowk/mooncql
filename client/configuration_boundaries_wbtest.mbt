///|
test "connection configuration rejects boundary errors with parameter name and range before transport" {
  let defaults = Config::new()
  for
    (name, invalid) in [
      ("connect_timeout_ms", { ..defaults, connect_timeout_ms: 0, }),
      ("timeout_ms", { ..defaults, timeout_ms: -1, }),
      ("queue_timeout_ms", { ..defaults, queue_timeout_ms: 0, }),
      (
        "operation_timeout_ms",
        { ..defaults, operation_timeout_ms: -2147483648, },
      ),
      ("max_frame_bytes", { ..defaults, max_frame_bytes: 0, }),
      ("port", { ..defaults, port: 65536, }),
      ("max_in_flight", { ..defaults, max_in_flight: 32769, }),
      ("max_in_flight_bytes", { ..defaults, max_in_flight_bytes: 8, }),
      ("max_waiting", { ..defaults, max_waiting: 1048577, }),
      ("max_waiting_bytes", { ..defaults, max_waiting_bytes: -1, }),
      ("max_auth_rounds", { ..defaults, max_auth_rounds: 129, }),
      ("max_auth_token_bytes", { ..defaults, max_auth_token_bytes: 16777217, }),
      (
        "prepared_cache_capacity",
        { ..defaults, prepared_cache_capacity: 65537, },
      ),
      ("max_abandoned", { ..defaults, max_abandoned: 32769, }),
      ("event_capacity", { ..defaults, event_capacity: 0, }),
      ("heartbeat_interval_ms", { ..defaults, heartbeat_interval_ms: -1, }),
      ("heartbeat_timeout_ms", { ..defaults, heartbeat_timeout_ms: 0, }),
      ("abandoned_timeout_ms", { ..defaults, abandoned_timeout_ms: 0, }),
    ] {
    assert_true(
      try {
        invalid.validate()
        false
      } catch {
        Configuration(message) =>
          message.contains(name) && message.contains("..")
        _ => false
      },
    )
  }
  {
    ..defaults,
    max_waiting: 0,
    heartbeat_interval_ms: 0,
    max_auth_token_bytes: 0,
    prepared_cache_capacity: 0,
    max_abandoned: 0,
    timeout_ms: 2147483647,
    operation_timeout_ms: 2147483647,
    max_in_flight_bytes: 2147483647,
    max_waiting_bytes: 2147483647,
  }.validate()
}

///|
test "shared limits reject impossible sizes without waiting and do not overflow accumulated bytes" {
  let defaults = SessionLimits::new()
  for
    (name, invalid) in [
      ("max_in_flight", { ..defaults, max_in_flight: 0, }),
      ("max_in_flight", { ..defaults, max_in_flight: 1048577, }),
      ("max_in_flight_bytes", { ..defaults, max_in_flight_bytes: 8, }),
      ("max_waiting", { ..defaults, max_waiting: -1, }),
      ("max_waiting_bytes", { ..defaults, max_waiting_bytes: -1, }),
    ] {
    assert_true(
      try {
        invalid.validate()
        false
      } catch {
        Configuration(message) =>
          message.contains(name) && message.contains("..")
        _ => false
      },
    )
  }
  let parent = Admission::new(
    Config::new(max_in_flight_bytes=2147483647, max_waiting_bytes=2147483647),
    session=true,
  )
  let child = Admission::new(
    Config::new(max_in_flight_bytes=2147483647, max_waiting_bytes=2147483647),
    parent~,
  )
  let held = child.register(2147483647L)
  let next = child.register(2147483647L)
  assert_eq(parent.bytes, 2147483647L)
  assert_eq(parent.waiting_bytes, 2147483647L)
  assert_true(
    try {
      ignore(child.register(2147483648L))
      false
    } catch {
      Overloaded(SessionRequestTooLarge) => true
      _ => false
    },
  )
  child.release(next)
  child.release(held)
  assert_eq(parent.waiting_bytes, 0L)
  assert_eq(parent.bytes, 0L)
}
