///|
/// 可复用的执行策略；幂等性属于每次调用，不能由配置默认开启。
pub struct ExecutionProfile {
  settings : @protocol.QueryOptions
  timeout : Int?
  traversal_timeout : Int?
  policy : RetryPolicy
  backoff : RetryBackoff?
}

///|
/// 默认 LOCAL_ONE；显式页大小与预算须为正。重试策略不替代每次调用的幂等声明。
pub fn ExecutionProfile::new(
  consistency? : @protocol.Consistency = LocalOne,
  page_size? : Int,
  serial_consistency? : @protocol.Consistency,
  timeout_ms? : Int,
  traversal_timeout_ms? : Int,
  retry? : RetryPolicy = RetryPolicy::new(),
  backoff? : RetryBackoff,
) -> ExecutionProfile raise DriverError {
  if page_size is Some(value) {
    validate_range("profile.page_size", value, 1, 2147483647)
  }
  if timeout_ms is Some(value) {
    validate_range("profile.timeout_ms", value, 1, 2147483647)
  }
  if traversal_timeout_ms is Some(value) {
    validate_range("profile.traversal_timeout_ms", value, 1, 2147483647)
  }
  retry.validate()
  if serial_consistency is Some(level) &&
    level != Serial &&
    level != LocalSerial {
    raise Configuration(
      "profile.serial_consistency must be Serial or LocalSerial",
    )
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
    backoff,
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
/// 返回单次查询／取页预算；None 表示继承连接的操作预算。
pub fn ExecutionProfile::timeout_ms(self : ExecutionProfile) -> Int? {
  self.timeout
}

///|
/// 返回整个遍历的预算；None 表示不附加遍历期限，单页仍有操作预算。
pub fn ExecutionProfile::traversal_timeout_ms(self : ExecutionProfile) -> Int? {
  self.traversal_timeout
}

///|
/// 返回策略值副本，不使非幂等操作自动重放。
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
