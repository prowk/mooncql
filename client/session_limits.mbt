///|
/// 所有已建立连接共享固定总额度；增加节点不会扩大此预算。
pub(all) struct SessionLimits {
  max_in_flight : Int
  max_in_flight_bytes : Int
  max_waiting : Int
  max_waiting_bytes : Int
  overload_policy : OverloadPolicy
}

///|
pub fn SessionLimits::new(
  max_in_flight? : Int = 128,
  max_in_flight_bytes? : Int = 67108864,
  max_waiting? : Int = 64,
  max_waiting_bytes? : Int = 67108864,
  overload_policy? : OverloadPolicy = Wait,
) -> SessionLimits {
  {
    max_in_flight,
    max_in_flight_bytes,
    max_waiting,
    max_waiting_bytes,
    overload_policy,
  }
}

///|
fn SessionLimits::validate(self : SessionLimits) -> Unit raise DriverError {
  if self.max_in_flight < 1 ||
    self.max_in_flight > 1048576 ||
    self.max_in_flight_bytes < 9 ||
    self.max_waiting < 0 ||
    self.max_waiting > 1048576 ||
    self.max_waiting_bytes < 0 {
    raise Configuration("invalid Session total limits")
  }
}

///|
fn SessionLimits::as_config(self : SessionLimits, base : Config) -> Config {
  {
    ..base,
    max_in_flight: self.max_in_flight,
    max_in_flight_bytes: self.max_in_flight_bytes,
    max_waiting: self.max_waiting,
    max_waiting_bytes: self.max_waiting_bytes,
    overload_policy: self.overload_policy,
    metrics: None,
  }
}

///|
pub(all) struct SessionBudget {
  in_flight : Int
  in_flight_bytes : Int64
  waiting : Int
  waiting_bytes : Int64
  limits : SessionLimits
}

///|
pub fn Session::budget(self : Session) -> SessionBudget {
  {
    in_flight: self.admission.in_flight,
    in_flight_bytes: self.admission.bytes,
    waiting: self.admission.waiting,
    waiting_bytes: self.admission.waiting_bytes,
    limits: self.config.limits,
  }
}
