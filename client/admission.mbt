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
struct Admission {
  config : Config
  changed : @async.CondVar
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
fn Admission::new(config : Config) -> Admission {
  {
    config,
    changed: @async.CondVar::Cond(),
    closed: false,
    in_flight: 0,
    bytes: 0L,
    waiting: 0,
    waiting_bytes: 0L,
  }
}

///|
fn Admission::fits(self : Admission, bytes : Int64) -> Bool {
  self.in_flight < self.config.max_in_flight &&
  self.bytes + bytes <= self.config.max_in_flight_bytes.to_int64()
}

///|
fn Admission::register(
  self : Admission,
  bytes : Int64,
) -> Reservation raise DriverError {
  if self.closed {
    raise Closed
  }
  if bytes > self.config.max_in_flight_bytes.to_int64() {
    raise Overloaded(RequestTooLarge)
  }
  if !self.fits(bytes) {
    if self.config.overload_policy == Reject {
      raise Overloaded(
        if self.in_flight >= self.config.max_in_flight {
          InFlightLimit
        } else {
          ByteLimit
        },
      )
    }
    if self.waiting >= self.config.max_waiting {
      raise Overloaded(WaitingQueueFull)
    }
    if self.waiting_bytes + bytes > self.config.max_waiting_bytes.to_int64() {
      raise Overloaded(WaitingBytesFull)
    }
    self.waiting += 1
    self.waiting_bytes += bytes
    return { bytes, released: false, admitted: false, owned_by_pending: false, }
  }
  self.in_flight += 1
  self.bytes += bytes
  { bytes, released: false, admitted: true, owned_by_pending: false, }
}

///|
async fn Admission::admit(self : Admission, reservation : Reservation) -> Unit {
  if !reservation.admitted {
    while !self.closed && !self.fits(reservation.bytes) {
      self.changed.wait()
    }
    if self.closed {
      raise Closed
    }
    self.waiting -= 1
    self.waiting_bytes -= reservation.bytes
    reservation.admitted = true
    self.in_flight += 1
    self.bytes += reservation.bytes
  }
  if self.closed {
    raise Closed
  }
}

///|
fn Admission::release(self : Admission, reservation : Reservation) -> Unit {
  if !reservation.released {
    reservation.released = true
    if reservation.admitted {
      self.in_flight -= 1
      self.bytes -= reservation.bytes
    } else {
      self.waiting -= 1
      self.waiting_bytes -= reservation.bytes
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
