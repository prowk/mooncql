///|
pub(all) struct RetryPolicy {
  max_attempts : Int
  delay_ms : Int
}

///|
pub fn RetryPolicy::new(
  max_attempts? : Int = 3,
  delay_ms? : Int = 10,
) -> RetryPolicy {
  { max_attempts, delay_ms, }
}

///|
pub(all) struct AttemptFailure {
  attempt : Int
  endpoint : Endpoint?
  error : Error
  may_have_been_sent : Bool
  execution_info : ExecutionInfo?
}

///|
pub(all) suberror RetryExhausted {
  RetryExhausted(Array[AttemptFailure])
}

///|
priv suberror RetryPauseFinished

///|
async fn Session::retry_pause(self : Session, milliseconds : Int) -> Unit {
  if self.closed {
    raise Closed
  }
  if milliseconds == 0 {
    return
  }
  // 关闭时唤醒退避等待，不能让 Session.close 等待整个重试延迟。
  @async.with_timeout(
    milliseconds,
    () => {
      while !self.closed {
        self.changed.wait()
      }
      raise Closed
    },
    error=RetryPauseFinished,
  ) catch {
    RetryPauseFinished => ()
    error => raise error
  }
}

///|
fn retryable(error : Error) -> Bool {
  match error {
    Closed | HeartbeatFailed | @io.ReaderClosed | @os_error.OSError(_, ..) =>
      true
    TimedOut(info) => info.scope == Execution || info.scope == Queue
    Overloaded(InFlightLimit | ByteLimit | WaitingQueueFull | WaitingBytesFull) =>
      true
    Server(server) =>
      match server.detail {
        Unavailable(_, _, _)
        | ReadTimeout(_, _, _, _)
        | ReadFailure(_, _, _, _, _) => true
        WriteTimeout(_, _, _, kind, _) | WriteFailure(_, _, _, _, kind) =>
          kind == "SIMPLE"
        _ => server.code == 0x1001 || server.code == 0x1002
      }
    _ => false
  }
}

///|
fn possibly_sent(error : Error, endpoint : Endpoint?) -> Bool {
  match error {
    TimedOut(info) => info.may_have_been_sent
    Overloaded(_) | Configuration(_) => false
    _ => endpoint is Some(_)
  }
}

///|
async fn[T] Session::execute_retry(
  self : Session,
  deadline : Deadline,
  bytes : Int64,
  idempotent : Bool,
  policy : RetryPolicy,
  hint : RoutingHint?,
  action : async (Connection) -> T,
  complete? : (T, Array[AttemptFailure]) -> T,
) -> T {
  if policy.max_attempts < 1 || policy.max_attempts > 64 || policy.delay_ms < 0 {
    raise Configuration("invalid retry policy")
  }
  let enabled = idempotent && policy.max_attempts > 1
  let failures = []
  let mut any_sent = false
  let attempted = []
  for attempt = 1; ; attempt = attempt + 1 {
    let mut endpoint = None
    let outcome = try {
      let connection = self.select(deadline, bytes, hint?, attempted~)
      attempted.push("\{connection.config.host}:\{connection.config.port}")
      endpoint = Some(
        Endpoint::new(host=connection.config.host, port=connection.config.port),
      )
      Ok(action(connection))
    } catch {
      error => Err(error)
    }
    match outcome {
      Ok(value) =>
        return match complete {
          Some(complete) => complete(value, failures)
          None => value
        }
      Err(error) => {
        if !enabled {
          raise error
        }
        let (cause, info) = match error {
          ExecutionError(cause, info) => (cause, Some(info))
          _ => (error, None)
        }
        let sent = possibly_sent(cause, endpoint)
        any_sent = any_sent || sent
        failures.push({
          attempt,
          endpoint,
          error: cause,
          may_have_been_sent: sent,
          execution_info: info,
        })
        if attempt >= policy.max_attempts || !retryable(cause) || self.closed {
          raise RetryExhausted(failures)
        }
      }
    }
    // 重试等待本身也消耗原预算，不延长总截止时间。
    let observation = match self.config.connection.metrics {
      Some(metrics) => Some(WaitObservation::new(metrics, Retry, 0L))
      None => None
    }
    defer (if observation is Some(observation) { observation.finish() })
    let pause = try {
      timed(
        deadline.remaining_ms(),
        Operation,
        { phase: WaitingRetry, sent: any_sent, },
        () => self.retry_pause(policy.delay_ms),
      )
      None
    } catch {
      error => Some(error)
    }
    if observation is Some(observation) {
      observation.outcome = match pause {
        Some(error) => request_outcome(error)
        None => Succeeded
      }
      observation.finish()
    }
    if pause is Some(error) {
      failures.push({
        attempt: attempt + 1,
        endpoint: None,
        error,
        may_have_been_sent: any_sent,
        execution_info: None,
      })
      raise RetryExhausted(failures)
    }
  }
}
