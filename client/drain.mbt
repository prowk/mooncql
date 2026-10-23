///|
/// 排空只表示已接受操作全部结束，不表示每个业务操作均执行成功。
pub(all) enum DrainOutcome {
  Drained
  DeadlineReached(Int)
  Interrupted(Int)
} derive(Eq, @debug.Debug)

///|
pub extend DrainOutcome with Eq::{equal, not_equal}

///|
pub extend DrainOutcome with @debug.Debug::{to_repr}

///|
fn Session::begin_operation(self : Session) -> Unit raise DriverError {
  if self.closed {
    raise Closed
  }
  if self.draining {
    raise Draining
  }
  self.active += 1
}

///|
pub fn Session::is_draining(self : Session) -> Bool {
  self.draining && !self.closed
}

///|
pub fn Connection::is_draining(self : Connection) -> Bool {
  self.draining && !self.closed
}

///|
fn Connection::pause_health(self : Connection) -> Unit {
  if self.health_task is Some(task) {
    task.cancel()
  }
}

///|
/// 停止接收新逻辑操作并停止后台恢复；共享一次排空结果，最终始终等待资源关闭。
pub async fn Session::drain(
  self : Session,
  deadline : Deadline,
) -> DrainOutcome {
  if self.closed {
    self.close()
    return self.drain_outcome.unwrap_or(Drained)
  }
  self.draining = true
  if self.control is Some(control) {
    if control.connection is Some(connection) {
      connection.close()
    }
    if control.worker is Some(worker) {
      worker.cancel()
    }
  }
  for node in self.nodes {
    for slot in node.slots {
      if slot.current is Some(connection) {
        connection.pause_health()
      }
    }
    if node.representative() is None && node.worker is Some(worker) {
      worker.cancel()
    }
  }
  self.changed.broadcast()
  // 正常、超时、外部取消都必须关闭并等待后台任务及已接受调用收尾。
  defer @async.protect_from_cancel(() => self.close())
  let expired = try {
    timed(
      deadline.remaining_ms(),
      Operation,
      { phase: WaitingDrain, sent: false, },
      () => {
        while self.active > 0 && !self.closed {
          self.changed.wait()
        }
      },
    )
    false
  } catch {
    TimedOut(_) => true
    error => raise error
  }
  if self.drain_outcome is None {
    self.drain_outcome = Some(
      if expired && self.active > 0 {
        DeadlineReached(self.active)
      } else {
        Drained
      },
    )
  }
  self.drain_outcome.unwrap_or(Drained)
}

///|
fn Connection::drain_remaining(self : Connection) -> Int {
  if self.active_requests > self.pending.length() {
    self.active_requests
  } else {
    self.pending.length()
  }
}

///|
/// 排空本连接已接受的 RPC（含排队者和迟到响应），不接收新的 RPC。
pub async fn Connection::drain(
  self : Connection,
  deadline : Deadline,
) -> DrainOutcome {
  if self.closed {
    self.shutdown()
    return self.drain_outcome.unwrap_or(Drained)
  }
  self.draining = true
  self.pause_health()
  defer @async.protect_from_cancel(() => self.shutdown())
  let expired = try {
    timed(
      deadline.remaining_ms(),
      Operation,
      { phase: WaitingDrain, sent: false, },
      () => {
        while self.drain_remaining() > 0 && !self.closed {
          self.closed_changed.wait()
        }
      },
    )
    false
  } catch {
    TimedOut(_) => true
    error => raise error
  }
  if self.drain_outcome is None {
    self.drain_outcome = Some(
      if expired && self.drain_remaining() > 0 {
        DeadlineReached(self.drain_remaining())
      } else {
        Drained
      },
    )
  }
  self.drain_outcome.unwrap_or(Drained)
}
