///|
fn retry_server_error(
  code : Int32,
  detail~ : @protocol.ErrorDetail = Other(b""),
) -> Error {
  Server({ code, message: "busy", detail, })
}

///|
test "backoff class exponential cap and seeded full jitter bounds" {
  let policy = RetryBackoff::new(
    local_ms=2,
    overloaded_ms=5,
    bootstrapping_ms=11,
    network_ms=7,
    read_timeout_ms=13,
    max_delay_ms=100,
    jitter=0.0,
  )
  let cases : Array[(Error, Int32)] = [
    (SessionOverloaded(ByteLimit), 2),
    (
      TimedOut({ phase: WaitingSlot, scope: Queue, may_have_been_sent: false, }),
      2,
    ),
    (retry_server_error(0x1001), 5),
    (retry_server_error(0x1002), 11),
    (Closed, 7),
    (retry_server_error(0x1200, detail=ReadTimeout(1, 1, 2, false)), 13),
  ]
  for (error, base) in cases {
    assert_eq(policy.delay(error, 1, 0.0), base)
    assert_eq(policy.delay(error, 2, 0.9), base * 2)
    assert_eq(policy.delay(error, 64, 0.5), 100)
  }
  let enormous = RetryBackoff::new(
    network_ms=2147483647,
    max_delay_ms=2147483647,
    jitter=0.0,
  )
  assert_eq(enormous.delay(Closed, 64, 0.999), 2147483647)
  let jitter = RetryBackoff::new(overloaded_ms=100, max_delay_ms=1000)
  let first = @random.Rand::chacha8(seed=b"ABCDEFGHIJKLMNOPQRSTUVWXYZ123456")
  let replay = @random.Rand::chacha8(seed=b"ABCDEFGHIJKLMNOPQRSTUVWXYZ123456")
  let distinct : Map[Int32, Bool] = Map([])
  for _ in 0..<64 {
    let delay = jitter.delay(retry_server_error(0x1001), 2, first.double())
    assert_eq(
      delay,
      jitter.delay(retry_server_error(0x1001), 2, replay.double()),
    )
    assert_true(delay >= 0 && delay <= 200)
    distinct[delay] = true
  }
  assert_true(distinct.length() > 32)
}

///|
test "backoff constructor rejects invalid class delays cap and jitter" {
  for bad in [-2147483648, -1, 1001, 2147483647] {
    assert_true(
      try {
        ignore(RetryBackoff::new(local_ms=bad))
        false
      } catch {
        Configuration(message) => message.contains("local_ms")
        _ => false
      },
    )
  }
  for bad in [-1.0, 1.1, 0.0 / 0.0] {
    assert_true(
      try {
        ignore(RetryBackoff::new(jitter=bad))
        false
      } catch {
        Configuration(message) => message.contains("jitter")
        _ => false
      },
    )
  }
}
