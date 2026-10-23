///|
pub(all) enum TimeoutPhase {
  Connecting
  WaitingSlot
  WaitingWriteLock
  Sending
  WaitingResponse
  WaitingPrepare
  WaitingConnection
  WaitingRetry
  WaitingDrain
  WaitingSchema
  WaitingPage
} derive(Eq, @debug.Debug)

///|
pub extend TimeoutPhase with Eq::{equal, not_equal}

///|
pub extend TimeoutPhase with @debug.Debug::{to_repr}

///|
pub(all) enum TimeoutScope {
  Connection
  Queue
  Execution
  Operation
} derive(Eq, @debug.Debug)

///|
pub extend TimeoutScope with Eq::{equal, not_equal}

///|
pub extend TimeoutScope with @debug.Debug::{to_repr}

///|
pub(all) struct TimeoutInfo {
  phase : TimeoutPhase
  scope : TimeoutScope
  may_have_been_sent : Bool
} derive(@debug.Debug)

///|
pub extend TimeoutInfo with @debug.Debug::{to_repr}

///|
pub struct Deadline {
  at : Int64
}

///|
pub fn Deadline::after(milliseconds : Int) -> Deadline raise DriverError {
  if milliseconds <= 0 {
    raise Configuration("deadline must be positive")
  }
  { at: @async.now() + milliseconds.to_int64(), }
}

///|
pub fn Deadline::remaining_ms(self : Deadline) -> Int {
  let remaining = self.at - @async.now()
  if remaining <= 0L {
    0
  } else if remaining > 2147483647L {
    2147483647
  } else {
    remaining.to_int()
  }
}

///|
priv struct TimeoutContext {
  mut phase : TimeoutPhase
  mut sent : Bool
}

///|
priv suberror ClockExpired

///|
async fn[T] timed(
  milliseconds : Int,
  scope : TimeoutScope,
  context : TimeoutContext,
  action : async () -> T,
) -> T {
  if milliseconds <= 0 {
    raise TimedOut({
      phase: context.phase,
      scope,
      may_have_been_sent: context.sent,
    })
  }
  @async.with_timeout(milliseconds, action, error=ClockExpired) catch {
    ClockExpired =>
      raise TimedOut({
        phase: context.phase,
        scope,
        may_have_been_sent: context.sent,
      })
    error => raise error
  }
}

///|
async fn[T] Deadline::with_lock(
  self : Deadline,
  mutex : @async.Mutex,
  body : async () -> T,
  metrics? : Metrics,
  admission? : Admission,
  bytes? : Int64 = 0L,
) -> T {
  let observation = match metrics {
    Some(metrics) => Some(WaitObservation::new(metrics, Prepare, bytes))
    None => None
  }
  defer (if observation is Some(observation) { observation.finish() })
  // 同步探测锁；仅真实等待者进入额度队列，持有标记覆盖计时器收尾。
  let mut acquired = false
  let mut waiting = false
  defer {
    if acquired {
      mutex.release()
    }
    if waiting && admission is Some(admission) {
      admission.leave_wait(bytes)
    }
  }
  let outcome = try {
    if self.remaining_ms() <= 0 {
      raise TimedOut({
        phase: WaitingPrepare,
        scope: Operation,
        may_have_been_sent: false,
      })
    }
    if mutex.try_acquire() {
      acquired = true
    } else {
      if admission is Some(admission) {
        admission.enter_wait(bytes)
        waiting = true
      }
      timed(
        self.remaining_ms(),
        Operation,
        { phase: WaitingPrepare, sent: false, },
        () => {
          mutex.acquire()
          acquired = true
        },
      )
    }
    Ok(())
  } catch {
    error => Err(error)
  }
  match outcome {
    Err(error) => {
      if observation is Some(observation) {
        observation.outcome = request_outcome(error)
      }
      raise error
    }
    Ok(_) => {
      if waiting && admission is Some(admission) {
        admission.leave_wait(bytes)
        waiting = false
      }
      if observation is Some(observation) {
        observation.outcome = Succeeded
        observation.finish()
      }
      body()
    }
  }
}

///|
fn Connection::operation_deadline(
  self : Connection,
  deadline : Deadline?,
) -> Deadline raise DriverError {
  match deadline {
    Some(deadline) => deadline
    None => Deadline::after(self.config.operation_timeout_ms)
  }
}
