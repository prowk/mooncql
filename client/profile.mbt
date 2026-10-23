///|
/// 可复用的执行策略；幂等性属于每次调用，不能由配置默认开启。
pub struct ExecutionProfile {
  settings : @protocol.QueryOptions
  timeout : Int?
  traversal_timeout : Int?
  policy : RetryPolicy
}

///|
pub fn ExecutionProfile::new(
  consistency? : @protocol.Consistency = LocalOne,
  page_size? : Int,
  serial_consistency? : @protocol.Consistency,
  timeout_ms? : Int,
  traversal_timeout_ms? : Int,
  retry? : RetryPolicy = RetryPolicy::new(),
) -> ExecutionProfile raise DriverError {
  if (page_size is Some(size) && size <= 0) ||
    (timeout_ms is Some(timeout) && timeout <= 0) ||
    (traversal_timeout_ms is Some(timeout) && timeout <= 0) ||
    retry.max_attempts < 1 ||
    retry.max_attempts > 64 ||
    retry.delay_ms < 0 {
    raise Configuration("invalid execution profile")
  }
  if serial_consistency is Some(level) &&
    level != Serial &&
    level != LocalSerial {
    raise Configuration("invalid profile serial consistency")
  }
  {
    settings: @protocol.QueryOptions::new(
      consistency~,
      page_size?,
      serial_consistency?,
    ),
    timeout: timeout_ms,
    traversal_timeout: traversal_timeout_ms,
    policy: retry,
  }
}

///|
/// 返回独立选项，便于在单次调用中显式覆盖时间戳、keyspace 等字段。
pub fn ExecutionProfile::options(
  self : ExecutionProfile,
) -> @protocol.QueryOptions {
  self.settings.snapshot()
}

///|
pub fn ExecutionProfile::timeout_ms(self : ExecutionProfile) -> Int? {
  self.timeout
}

///|
pub fn ExecutionProfile::traversal_timeout_ms(self : ExecutionProfile) -> Int? {
  self.traversal_timeout
}

///|
pub fn ExecutionProfile::retry_policy(self : ExecutionProfile) -> RetryPolicy {
  self.policy
}

///|
fn profile_options(
  profile : ExecutionProfile?,
  explicit : @protocol.QueryOptions?,
  paging? : Bool = false,
) -> @protocol.QueryOptions {
  if explicit is Some(options) {
    return options.snapshot()
  }
  let options = profile
    .map(profile => profile.options())
    .unwrap_or_else(() => @protocol.QueryOptions::new())
  if paging && options.page_size is None {
    { ..options, page_size: Some(1000), }
  } else {
    options
  }
}

///|
fn profile_deadline(
  profile : ExecutionProfile?,
  explicit : Deadline?,
  fallback : Int,
) -> Deadline raise DriverError {
  explicit.unwrap_or_else(() => {
    Deadline::after(
      profile.bind(profile => profile.timeout).unwrap_or(fallback),
    )
  })
}

///|
fn profile_retry(
  profile : ExecutionProfile?,
  explicit : RetryPolicy?,
) -> RetryPolicy {
  explicit.unwrap_or_else(() => {
    profile
    .map(profile => profile.policy)
    .unwrap_or_else(() => RetryPolicy::new())
  })
}

///|
fn Session::execution_profile(
  self : Session,
  explicit : ExecutionProfile?,
) -> ExecutionProfile? {
  match explicit {
    Some(_) => explicit
    None => self.config.execution_profile
  }
}

///|
fn SessionPrepared::execution_profile(
  self : SessionPrepared,
  explicit : ExecutionProfile?,
) -> ExecutionProfile? {
  match explicit {
    Some(_) => explicit
    None => self.profile
  }
}
