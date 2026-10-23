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
  SessionInFlightLimit
  SessionByteLimit
  SessionWaitingQueueFull
  SessionWaitingBytesFull
  SessionRequestTooLarge
} derive(Eq, @debug.Debug)

///|
pub extend OverloadReason with Eq::{equal, not_equal}

///|
pub extend OverloadReason with @debug.Debug::{to_repr}

///|
struct Admission {
  config : Config
  changed : @async.CondVar
  parent : Admission?
  session : Bool
  mut closed : Bool
  mut in_flight : Int
  mut bytes : Int64
  mut waiting : Int
  mut waiting_bytes : Int64
}

///|
priv struct Reservation {
  bytes : Int64
  mut released : Bool
  mut admitted : Bool
  mut owned_by_pending : Bool
}

///|
fn Admission::new(
  config : Config,
  parent? : Admission,
  changed? : @async.CondVar,
  session? : Bool = false,
) -> Admission {
  {
    config,
    changed: parent
    .map(parent => parent.changed)
    .unwrap_or_else(() => changed.unwrap_or_else(() => @async.CondVar::Cond())),
    parent,
    session,
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
fn Admission::block_reason(self : Admission, bytes : Int64) -> OverloadReason? {
  if self.parent is Some(parent) && parent.block_reason(bytes) is Some(reason) {
    return Some(reason)
  }
  if self.in_flight >= self.config.max_in_flight {
    Some(if self.session { SessionInFlightLimit } else { InFlightLimit })
  } else if bytes > self.config.max_in_flight_bytes.to_int64() - self.bytes {
    Some(if self.session { SessionByteLimit } else { ByteLimit })
  } else {
    None
  }
}

///|
fn Admission::validate_size(
  self : Admission,
  bytes : Int64,
) -> Unit raise DriverError {
  if self.is_closed() {
    raise Closed
  }
  if self.parent is Some(parent) {
    parent.validate_size(bytes)
  }
  if bytes > self.config.max_in_flight_bytes.to_int64() {
    raise Overloaded(
      if self.session {
        SessionRequestTooLarge
      } else {
        RequestTooLarge
      },
    )
  }
}

///|
fn Admission::rejects(self : Admission) -> Bool {
  self.config.overload_policy == Reject ||
  (self.parent is Some(parent) && parent.rejects())
}

///|
fn Admission::waiting_reason(
  self : Admission,
  bytes : Int64,
) -> OverloadReason? {
  if self.parent is Some(parent) && parent.waiting_reason(bytes) is Some(reason) {
    return Some(reason)
  }
  if self.waiting >= self.config.max_waiting {
    Some(if self.session { SessionWaitingQueueFull } else { WaitingQueueFull })
  } else if bytes >
    self.config.max_waiting_bytes.to_int64() - self.waiting_bytes {
    Some(if self.session { SessionWaitingBytesFull } else { WaitingBytesFull })
  } else {
    None
  }
}

///|
// 子连接与 Session 在同一同步步骤记账，等待、取消及迟到响应使用同一所有权。
fn Admission::change_wait(self : Admission, bytes : Int64, delta : Int) -> Unit {
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
  delta : Int,
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
fn Admission::enter_wait(
  self : Admission,
  bytes : Int64,
) -> Unit raise DriverError {
  self.validate_size(bytes)
  if self.waiting_reason(bytes) is Some(reason) {
    raise Overloaded(reason)
  }
  self.change_wait(bytes, 1)
}

///|
fn Admission::leave_wait(self : Admission, bytes : Int64) -> Unit {
  self.change_wait(bytes, -1)
  self.changed.broadcast()
}

///|
fn Admission::register(
  self : Admission,
  bytes : Int64,
) -> Reservation raise DriverError {
  self.validate_size(bytes)
  if self.block_reason(bytes) is Some(reason) {
    if self.rejects() {
      raise Overloaded(reason)
    }
    self.enter_wait(bytes)
    return { bytes, released: false, admitted: false, owned_by_pending: false, }
  }
  self.change_active(bytes, 1)
  { bytes, released: false, admitted: true, owned_by_pending: false, }
}

///|
async fn Admission::admit(self : Admission, reservation : Reservation) -> Unit {
  if !reservation.admitted {
    while !self.is_closed() && !self.fits(reservation.bytes) {
      self.changed.wait()
    }
    if self.is_closed() {
      raise Closed
    }
    self.change_wait(reservation.bytes, -1)
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
    }
    self.changed.broadcast()
  }
}

///|
fn Admission::close(self : Admission) -> Unit {
  self.closed = true
  self.changed.broadcast()
}

///|
pub fn Connection::waiting_count(self : Connection) -> Int {
  self.admission.waiting
}

///|
pub fn Connection::in_flight_count(self : Connection) -> Int {
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
