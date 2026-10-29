///|
pub(all) enum OverloadPolicy {
  Wait
  Reject
} derive(Eq, @debug.Debug)

///|
pub extend OverloadPolicy with Eq::{equal, not_equal}

///|
pub extend OverloadPolicy with @debug.Debug::{to_repr}

///|
pub(all) enum OverloadReason {
  InFlightLimit
  ByteLimit
  WaitingQueueFull
  WaitingBytesFull
  RequestTooLarge
} derive(Eq, @debug.Debug)

///|
pub extend OverloadReason with Eq::{equal, not_equal}

///|
pub extend OverloadReason with @debug.Debug::{to_repr}

///|
/// Session 总预算使用独立错误，保留稳定版 OverloadReason 的封闭分支。
pub(all) suberror SessionOverloaded {
  SessionOverloaded(OverloadReason)
} derive(@debug.Debug)

///|
pub extend SessionOverloaded with @debug.Debug::{to_repr}

///|
fn is_session_budget_error(error : Error) -> Bool {
  match error {
    SessionOverloaded(_) => true
    ExecutionError(cause, _) | SchemaMetadataError(_, cause) =>
      is_session_budget_error(cause)
    RetryExhausted(history) =>
      history
      .last()
      .map(item => is_session_budget_error(item.error))
      .unwrap_or(false)
    _ => false
  }
}

///|
fn Admission::overload_error(
  self : Admission,
  reason : OverloadReason,
) -> Error {
  if self.session {
    SessionOverloaded(reason)
  } else {
    Overloaded(reason)
  }
}

///|
struct Admission {
  config : ConnectionBuilder
  changed : @async.CondVar
  parent : Admission?
  session : Bool
  enforce : Bool
  turns : Array[AdmissionTurn]
  scheduling : SchedulingCounters
  mut closed : Bool
  mut in_flight : Int32
  mut bytes : Int64
  mut waiting : Int32
  mut waiting_bytes : Int64
}

///|
priv struct SchedulingCounters {
  mut broadcasts : Int64
  mut wakeups : Int64
}

///|
/// 仅统计额度队列的通知和唤醒；不含 socket、准备锁或节点发现的唤醒。
pub(all) struct SchedulingSnapshot {
  broadcasts : Int64
  wakeups : Int64
  queued : Int32
}

///|
fn Admission::scheduling_snapshot(self : Admission) -> SchedulingSnapshot {
  {
    broadcasts: self.scheduling.broadcasts,
    wakeups: self.scheduling.wakeups,
    queued: self.turns.length(),
  }
}

///|
pub fn Connection::scheduling(self : Connection) -> SchedulingSnapshot {
  self.admission.scheduling_snapshot()
}

///|
pub fn Session::scheduling(self : Session) -> SchedulingSnapshot {
  self.admission.scheduling_snapshot()
}

///|
fn Admission::signal(self : Admission) -> Unit {
  self.scheduling.broadcasts += 1L
  self.changed.broadcast()
}

///|
priv struct AdmissionTurn {
  // 以对象身份标识排队顺序，避免长期运行时序号溢出。
  bytes : Int64
}

///|
priv struct Reservation {
  bytes : Int64
  mut released : Bool
  mut admitted : Bool
  mut owned_by_pending : Bool
  mut turn : AdmissionTurn?
}

///|
fn Admission::new(
  config : ConnectionBuilder,
  parent? : Admission,
  changed? : @async.CondVar,
  session~ : Bool = false,
  enforce~ : Bool = true,
) -> Admission {
  {
    config,
    changed: parent
    .map(parent => parent.changed)
    .unwrap_or_else(() => changed.unwrap_or_else(() => @async.CondVar::Cond())),
    parent,
    session,
    enforce,
    turns: parent.map(parent => parent.turns).unwrap_or_else(() => []),
    scheduling: parent
    .map(parent => parent.scheduling)
    .unwrap_or_else(() => { broadcasts: 0L, wakeups: 0L, }),
    closed: false,
    in_flight: 0,
    bytes: 0L,
    waiting: 0,
    waiting_bytes: 0L,
  }
}

///|
fn Admission::fits(self : Admission, bytes : Int64) -> Bool {
  !self.is_closed() && self.block_reason(bytes) is None
}

///|
fn Admission::is_closed(self : Admission) -> Bool {
  self.closed || (self.parent is Some(parent) && parent.is_closed())
}

///|
fn Admission::block_reason(self : Admission, bytes : Int64) -> Error? {
  if self.parent is Some(parent) && parent.block_reason(bytes) is Some(reason) {
    return Some(reason)
  }
  if !self.enforce {
    return None
  }
  if self.in_flight >= self.config.max_in_flight {
    Some(self.overload_error(InFlightLimit))
  } else if bytes > self.config.max_in_flight_bytes.to_int64() - self.bytes {
    Some(self.overload_error(ByteLimit))
  } else {
    None
  }
}

///|
fn Admission::validate_size(self : Admission, bytes : Int64) -> Unit raise {
  if bytes < 0L {
    raise Configuration("request bytes must be nonnegative")
  }
  if self.is_closed() {
    raise Closed
  }
  if self.parent is Some(parent) {
    parent.validate_size(bytes)
  }
  if self.enforce && bytes > self.config.max_in_flight_bytes.to_int64() {
    raise self.overload_error(RequestTooLarge)
  }
}

///|
fn Admission::rejects(self : Admission) -> Bool {
  (self.enforce && self.config.overload_policy == Reject) ||
  (self.parent is Some(parent) && parent.rejects())
}

///|
fn Admission::waiting_reason(self : Admission, bytes : Int64) -> Error? {
  if self.parent is Some(parent) && parent.waiting_reason(bytes) is Some(reason) {
    return Some(reason)
  }
  if !self.enforce {
    return None
  }
  if self.waiting >= self.config.max_waiting {
    Some(self.overload_error(WaitingQueueFull))
  } else if bytes >
    self.config.max_waiting_bytes.to_int64() - self.waiting_bytes {
    Some(self.overload_error(WaitingBytesFull))
  } else {
    None
  }
}

///|
// 子连接与 Session 在同一同步步骤记账，等待、取消及迟到响应使用同一所有权。
fn Admission::change_wait(
  self : Admission,
  bytes : Int64,
  delta : Int32,
) -> Unit {
  self.waiting += delta
  self.waiting_bytes += bytes * delta.to_int64()
  if self.config.metrics is Some(metrics) {
    metrics.gauges(0L, 0L, delta.to_int64(), bytes * delta.to_int64())
  }
  if self.parent is Some(parent) {
    parent.change_wait(bytes, delta)
  }
}

///|
fn Admission::change_active(
  self : Admission,
  bytes : Int64,
  delta : Int32,
) -> Unit {
  self.in_flight += delta
  self.bytes += bytes * delta.to_int64()
  if self.config.metrics is Some(metrics) {
    metrics.gauges(delta.to_int64(), bytes * delta.to_int64(), 0L, 0L)
  }
  if self.parent is Some(parent) {
    parent.change_active(bytes, delta)
  }
}

///|
fn Admission::enter_wait(self : Admission, bytes : Int64) -> Unit raise {
  self.validate_size(bytes)
  if self.waiting_reason(bytes) is Some(reason) {
    raise reason
  }
  self.change_wait(bytes, 1)
}

///|
fn Admission::leave_wait(self : Admission, bytes : Int64) -> Unit {
  self.change_wait(bytes, -1)
  self.signal()
}

///|
fn Admission::register(self : Admission, bytes : Int64) -> Reservation raise {
  self.validate_size(bytes)
  if self.block_reason(bytes) is Some(_) || !self.turns.is_empty() {
    if self.rejects() {
      raise self
        .block_reason(bytes)
        .unwrap_or_else(() => self.overload_error(InFlightLimit))
    }
    self.enter_wait(bytes)
    let turn = self.enqueue_turn(bytes)
    return {
      bytes,
      released: false,
      admitted: false,
      owned_by_pending: false,
      turn: Some(turn),
    }
  }
  self.change_active(bytes, 1)
  {
    bytes,
    released: false,
    admitted: true,
    owned_by_pending: false,
    turn: None,
  }
}

///|
fn Admission::enqueue_turn(self : Admission, bytes : Int64) -> AdmissionTurn {
  let turn = AdmissionTurn::{ bytes, }
  self.turns.push(turn)
  turn
}

///|
fn Admission::owns_turn(self : Admission, turn : AdmissionTurn) -> Bool {
  !self.turns.is_empty() && physical_equal(self.turns[0], turn)
}

///|
fn Admission::remove_turn(self : Admission, turn : AdmissionTurn) -> Unit {
  for index in 0..<self.turns.length() {
    if physical_equal(self.turns[index], turn) {
      self.turns.remove(index) |> ignore
      self.signal()
      return
    }
  }
}

///|
async fn Admission::admit(self : Admission, reservation : Reservation) -> Unit {
  if !reservation.admitted {
    while !self.is_closed() &&
          (match reservation.turn {
            Some(turn) => !self.owns_turn(turn) || !self.fits(turn.bytes)
            None => !self.fits(reservation.bytes)
          }) {
      self.changed.wait()
      self.scheduling.wakeups += 1L
    }
    if self.is_closed() {
      raise Closed
    }
    self.change_wait(reservation.bytes, -1)
    if reservation.turn is Some(turn) {
      self.remove_turn(turn)
      reservation.turn = None
    }
    reservation.admitted = true
    self.change_active(reservation.bytes, 1)
  }
  if self.is_closed() {
    raise Closed
  }
}

///|
fn Admission::release(self : Admission, reservation : Reservation) -> Unit {
  if !reservation.released {
    reservation.released = true
    if reservation.admitted {
      self.change_active(reservation.bytes, -1)
    } else {
      self.change_wait(reservation.bytes, -1)
      if reservation.turn is Some(turn) {
        self.remove_turn(turn)
        reservation.turn = None
      }
    }
    self.signal()
  }
}

///|
fn Admission::close(self : Admission) -> Unit {
  self.closed = true
  self.signal()
}

///|
pub fn Connection::waiting_count(self : Connection) -> Int32 {
  self.admission.waiting
}

///|
pub fn Connection::in_flight_count(self : Connection) -> Int32 {
  self.admission.in_flight
}

///|
pub fn Connection::in_flight_bytes(self : Connection) -> Int64 {
  self.admission.bytes
}

///|
pub fn Connection::waiting_bytes(self : Connection) -> Int64 {
  self.admission.waiting_bytes
}
