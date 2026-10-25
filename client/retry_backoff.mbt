///|
/// 按失败类别选择起始延迟，指数增长后截断并施加有界随机抖动。
pub struct RetryBackoff {
  local_ms : Int
  overloaded_ms : Int
  bootstrapping_ms : Int
  network_ms : Int
  read_timeout_ms : Int
  maximum : Int
  jitter : Double
}

///|
pub fn RetryBackoff::new(
  local_ms? : Int = 5,
  overloaded_ms? : Int = 25,
  bootstrapping_ms? : Int = 100,
  network_ms? : Int = 10,
  read_timeout_ms? : Int = 25,
  max_delay_ms? : Int = 1000,
  jitter? : Double = 1.0,
) -> RetryBackoff raise DriverError {
  validate_range("max_delay_ms", max_delay_ms, 1, 2147483647)
  for
    (name, delay) in [
      ("local_ms", local_ms),
      ("overloaded_ms", overloaded_ms),
      ("bootstrapping_ms", bootstrapping_ms),
      ("network_ms", network_ms),
      ("read_timeout_ms", read_timeout_ms),
    ] {
    validate_range(name, delay, 0, max_delay_ms)
  }
  if !(jitter >= 0.0 && jitter <= 1.0) {
    raise Configuration("jitter must be 0..1")
  }
  {
    local_ms,
    overloaded_ms,
    bootstrapping_ms,
    network_ms,
    read_timeout_ms,
    maximum: max_delay_ms,
    jitter,
  }
}

///|
fn RetryBackoff::delay(
  self : RetryBackoff,
  error : Error,
  attempt : Int,
  random : Double,
) -> Int {
  let base = if local_admission_failure(error) {
    self.local_ms
  } else {
    match error {
      Server(server) =>
        if server.code == 0x1001 {
          self.overloaded_ms
        } else if server.code == 0x1002 {
          self.bootstrapping_ms
        } else if server.detail is ReadTimeout(_, _, _, _) {
          self.read_timeout_ms
        } else {
          self.network_ms
        }
      _ => self.network_ms
    }
  }
  let mut ceiling = base
  // 先比较再倍增；即使最大 Int 与第 64 次尝试也不会溢出。
  for _ in 1..<attempt {
    ceiling = if ceiling > self.maximum / 2 {
      self.maximum
    } else {
      ceiling * 2
    }
  }
  (ceiling.to_double() * (1.0 - self.jitter + self.jitter * random)).to_int()
}
