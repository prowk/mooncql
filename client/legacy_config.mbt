///|
/// 保留 0.2.0 的完整记录构造；高级认证使用独立 ConnectionBuilder。
pub(all) struct Config {
  host : String
  port : Int32
  username : String?
  password : String?
  timeout_ms : Int32
  connect_timeout_ms : Int32
  queue_timeout_ms : Int32
  operation_timeout_ms : Int32
  max_frame_bytes : Int32
  max_in_flight : Int32
  max_in_flight_bytes : Int32
  max_waiting : Int32
  max_waiting_bytes : Int32
  overload_policy : OverloadPolicy
  throw_on_overload : Bool
  compression : Bool
  tls : TlsConfig?
  prepared_cache_capacity : Int32
  max_abandoned : Int32
  abandoned_timeout_ms : Int32
  event_capacity : Int32
  heartbeat_interval_ms : Int32
  heartbeat_timeout_ms : Int32
  metrics : Metrics?
}

///|
pub fn Config::new(
  host~ : String = "127.0.0.1",
  port~ : Int32 = 9042,
  username? : String,
  password? : String,
  timeout_ms~ : Int32 = 10000,
  connect_timeout_ms? : Int32,
  queue_timeout_ms? : Int32,
  operation_timeout_ms? : Int32,
  max_frame_bytes~ : Int32 = 16777216,
  max_in_flight~ : Int32 = 128,
  max_in_flight_bytes~ : Int32 = 67108864,
  max_waiting~ : Int32 = 64,
  max_waiting_bytes~ : Int32 = 67108864,
  overload_policy~ : OverloadPolicy = Wait,
  throw_on_overload~ : Bool = false,
  compression~ : Bool = false,
  tls? : TlsConfig,
  prepared_cache_capacity~ : Int32 = 64,
  max_abandoned~ : Int32 = 64,
  abandoned_timeout_ms~ : Int32 = 30000,
  event_capacity~ : Int32 = 256,
  heartbeat_interval_ms~ : Int32 = 30000,
  heartbeat_timeout_ms~ : Int32 = 5000,
  metrics? : Metrics,
) -> Config {
  {
    host,
    port,
    username,
    password,
    timeout_ms,
    connect_timeout_ms: connect_timeout_ms.unwrap_or(timeout_ms),
    queue_timeout_ms: queue_timeout_ms.unwrap_or(timeout_ms),
    operation_timeout_ms: operation_timeout_ms.unwrap_or(timeout_ms),
    max_frame_bytes,
    max_in_flight,
    max_in_flight_bytes,
    max_waiting,
    max_waiting_bytes,
    overload_policy,
    throw_on_overload,
    compression,
    tls,
    prepared_cache_capacity,
    max_abandoned,
    abandoned_timeout_ms,
    event_capacity,
    heartbeat_interval_ms,
    heartbeat_timeout_ms,
    metrics,
  }
}

///|
pub(all) struct SessionConfig {
  connection : Config
  contact_points : Array[Endpoint]
  backoff_initial_ms : Int32
  backoff_max_ms : Int32
  jitter : Double
  stable_reset_ms : Int32
  routing : RoutingConfig?
  discovery : DiscoveryConfig?
}

///|
pub fn SessionConfig::new(
  connection~ : Config = Config::new(),
  contact_points~ : Array[Endpoint] = [],
  backoff_initial_ms~ : Int32 = 25,
  backoff_max_ms~ : Int32 = 2000,
  jitter~ : Double = 0.2,
  stable_reset_ms~ : Int32 = 1000,
  discovery? : DiscoveryConfig,
  routing? : RoutingConfig,
) -> SessionConfig {
  {
    connection,
    contact_points: contact_points.copy(),
    backoff_initial_ms,
    backoff_max_ms,
    jitter,
    stable_reset_ms,
    discovery,
    routing,
  }
}

///|
pub fn Config::builder(self : Config) -> ConnectionBuilder {
  {
    ..ConnectionBuilder::new(),
    host: self.host,
    port: self.port,
    username: self.username,
    password: self.password,
    timeout_ms: self.timeout_ms,
    connect_timeout_ms: self.connect_timeout_ms,
    queue_timeout_ms: self.queue_timeout_ms,
    operation_timeout_ms: self.operation_timeout_ms,
    max_frame_bytes: self.max_frame_bytes,
    max_in_flight: self.max_in_flight,
    max_in_flight_bytes: self.max_in_flight_bytes,
    max_waiting: self.max_waiting,
    max_waiting_bytes: self.max_waiting_bytes,
    overload_policy: self.overload_policy,
    throw_on_overload: self.throw_on_overload,
    compression: self.compression,
    tls: self.tls,
    prepared_cache_capacity: self.prepared_cache_capacity,
    max_abandoned: self.max_abandoned,
    abandoned_timeout_ms: self.abandoned_timeout_ms,
    event_capacity: self.event_capacity,
    heartbeat_interval_ms: self.heartbeat_interval_ms,
    heartbeat_timeout_ms: self.heartbeat_timeout_ms,
    metrics: self.metrics,
  }
}

///|
pub fn SessionConfig::builder(self : SessionConfig) -> SessionBuilder {
  {
    ..SessionBuilder::new(),
    connection: self.connection.builder(),
    contact_points: self.contact_points,
    backoff_initial_ms: self.backoff_initial_ms,
    backoff_max_ms: self.backoff_max_ms,
    jitter: self.jitter,
    stable_reset_ms: self.stable_reset_ms,
    routing: self.routing,
    discovery: self.discovery,
    enforce_limits: false,
  }
}

///|
pub async fn[G] connect(
  group : @async.TaskGroup[G],
  config~ : Config = Config::new(),
  deadline? : Deadline,
) -> Connection {
  connect_builder(group, config=config.builder(), deadline?)
}

///|
pub async fn[T] with_connection(
  config~ : Config = Config::new(),
  body : async (Connection) -> T,
) -> T {
  with_connection_builder(config=config.builder(), body)
}

///|
pub async fn[T] with_serial_connection(
  config~ : Config = Config::new(),
  body : async (Connection) -> T,
) -> T {
  with_serial_connection_builder(config=config.builder(), body)
}

///|
pub async fn[T] with_session(
  config~ : SessionConfig = SessionConfig::new(),
  body : async (Session) -> T,
) -> T {
  with_session_builder(config=config.builder(), body)
}
