///|
pub(all) struct DiscoveryConfig {
  refresh_interval_ms : Int
  debounce_ms : Int
  max_nodes : Int
  max_keyspaces : Int
  max_tokens_per_node : Int
  address_mapper : (@protocol.InetEndpoint) -> Endpoint?
}

///|
pub fn DiscoveryConfig::new(
  refresh_interval_ms? : Int = 30000,
  debounce_ms? : Int = 100,
  max_nodes? : Int = 1024,
  max_keyspaces? : Int = 4096,
  max_tokens_per_node? : Int = 4096,
  address_mapper? : (@protocol.InetEndpoint) -> Endpoint? = native_endpoint,
) -> DiscoveryConfig {
  {
    refresh_interval_ms,
    debounce_ms,
    max_nodes,
    max_tokens_per_node,
    max_keyspaces,
    address_mapper,
  }
}

///|
pub(all) struct TopologyNode {
  host_id : Bytes
  native : @protocol.InetEndpoint
  endpoint : Endpoint?
  data_center : String
  rack : String
  tokens : Array[Int64]
  schema_version : Bytes
}

///|
pub(all) struct TopologySnapshot {
  revision : Int
  refreshed_at : Int64
  cluster_name : String
  partitioner : String
  nodes : Array[TopologyNode]
  keyspaces : Map[String, @routing.Replication]
}

///|
struct ControlState {
  config : DiscoveryConfig
  mut worker : @async.Task[Unit]?
  mut connection : Connection?
  mut snapshot : TopologySnapshot?
  mut stale : Bool
  mut generation : Int
  mut refreshes : Int
  mut schema_epoch : Int
  mut last_error : Error?
  mut ring : @routing.Ring?
  mut locations : Map[String, (String, Bytes)]
}

///|
pub(all) struct ControlStatus {
  connected : Bool
  endpoint : Endpoint?
  generation : Int
  refreshes : Int
  stale : Bool
  last_error : Error?
}

///|
pub fn Session::topology(self : Session) -> TopologySnapshot? {
  match self.control {
    Some(control) =>
      control.snapshot.map(snapshot => {
        let keyspaces : Map[String, @routing.Replication] = Map([])
        for keyspace, replication in snapshot.keyspaces {
          keyspaces[keyspace] = replication.snapshot()
        }
        {
          ..snapshot,
          nodes: snapshot.nodes.map(node => {
            ..node,
            tokens: node.tokens.copy(),
          }),
          keyspaces,
        }
      })
    None => None
  }
}

///|
pub fn Session::control_status(self : Session) -> ControlStatus? {
  self.control.map(control => {
    connected: control.connection is Some(connection) && !connection.is_closed(),
    endpoint: control.connection.map(connection => {
      Endpoint::new(host=connection.config.host, port=connection.config.port)
    }),
    generation: control.generation,
    refreshes: control.refreshes,
    stale: control.stale,
    last_error: control.last_error,
  })
}

///|
fn native_endpoint(native : @protocol.InetEndpoint) -> Endpoint? {
  let bytes = native.address
  if bytes.length() == 4 {
    Some(
      Endpoint::new(
        host="\{bytes[0].to_int()}.\{bytes[1].to_int()}.\{bytes[2].to_int()}.\{bytes[3].to_int()}",
        port=native.port,
      ),
    )
  } else if bytes.length() == 16 {
    let groups = []
    for i in 0..<8 {
      let word = bytes[i * 2].to_int() * 256 + bytes[i * 2 + 1].to_int()
      groups.push(word.to_string(radix=16))
    }
    Some(Endpoint::new(host=groups.join(":"), port=native.port))
  } else {
    None
  }
}

///|
fn topology_text(
  page : @protocol.Page,
  row : Int,
  name : String,
) -> String raise {
  guard page.get(row, name) is Text(value) && !value.is_empty() else {
    raise Unexpected("invalid topology text: " + name)
  }
  value
}

///|
fn topology_uuid(
  page : @protocol.Page,
  row : Int,
  name : String,
) -> Bytes raise {
  guard page.get(row, name) is Uuid(value) && value.length() == 16 else {
    raise Unexpected("invalid topology UUID: " + name)
  }
  value
}

///|
fn topology_node(
  page : @protocol.Page,
  row : Int,
  is_local : Bool,
  config : DiscoveryConfig,
  connected : Endpoint,
) -> TopologyNode raise {
  let address_name = if is_local { "rpc_address" } else { "native_address" }
  let port_name = if is_local { "rpc_port" } else { "native_port" }
  guard page.get(row, address_name) is Inet(address) &&
    (address.length() == 4 || address.length() == 16) else {
    raise Unexpected("invalid topology native address")
  }
  guard page.get(row, port_name) is Integer(port) && port > 0 && port <= 65535 else {
    raise Unexpected("invalid topology native port")
  }
  guard page.get(row, "tokens") is SetValue(values) &&
    !values.is_empty() &&
    values.length() <= config.max_tokens_per_node else {
    raise Unexpected("invalid topology tokens")
  }
  let tokens = []
  let seen : Map[Int64, Bool] = Map([])
  for value in values {
    guard value is Text(text) else {
      raise Unexpected("invalid topology token")
    }
    let token = @string.parse_int64(text)
    if seen.contains(token) {
      raise Unexpected("duplicate node token")
    }
    seen[token] = true
    tokens.push(token)
  }
  let native = @protocol.InetEndpoint::{ address, port, }
  let wildcard = address.to_array().all(byte => byte == b'\x00')
  let endpoint = if is_local && wildcard {
    Some(connected)
  } else {
    (config.address_mapper)(native)
  }
  {
    host_id: topology_uuid(page, row, "host_id"),
    native,
    endpoint,
    data_center: topology_text(page, row, "data_center"),
    rack: topology_text(page, row, "rack"),
    tokens,
    schema_version: topology_uuid(page, row, "schema_version"),
  }
}

///|
async fn read_topology(
  connection : Connection,
  endpoint : Endpoint,
  config : DiscoveryConfig,
  revision : Int,
) -> TopologySnapshot {
  // 完整快照共用一个截止时间，失败时不发布半份成员列表。
  let deadline = Deadline::after(connection.config.operation_timeout_ms)
  guard connection.query(
      "SELECT host_id,rpc_address,rpc_port,data_center,rack,tokens,schema_version,partitioner,cluster_name FROM system.local WHERE key='local'",
      deadline~,
    )
    is Rows(local_page) &&
    local_page.rows.length() == 1 else {
    raise Unexpected("expected one system.local row")
  }
  let nodes = [topology_node(local_page, 0, true, config, endpoint)]
  let pager = connection.pages(
    "SELECT host_id,native_address,native_port,data_center,rack,tokens,schema_version FROM system.peers_v2",
    options=@protocol.QueryOptions::new(page_size=256),
  )
  let ids : Map[Bytes, Bool] = Map([])
  ids[nodes[0].host_id] = true
  while pager.next(deadline~) is Some(page) {
    for row in 0..<page.rows.length() {
      if nodes.length() >= config.max_nodes {
        raise Configuration("topology exceeds max_nodes")
      }
      let node = topology_node(page, row, false, config, endpoint)
      if ids.contains(node.host_id) {
        raise Unexpected("duplicate topology host_id")
      }
      ids[node.host_id] = true
      nodes.push(node)
    }
  }
  let keyspaces : Map[String, @routing.Replication] = Map([])
  let schemas = connection.pages(
    "SELECT keyspace_name,replication FROM system_schema.keyspaces",
    options=@protocol.QueryOptions::new(page_size=256),
  )
  while schemas.next(deadline~) is Some(page) {
    for row in 0..<page.rows.length() {
      if keyspaces.length() >= config.max_keyspaces {
        raise Configuration("metadata exceeds max_keyspaces")
      }
      let keyspace = topology_text(page, row, "keyspace_name")
      if keyspaces.contains(keyspace) {
        raise Unexpected("duplicate keyspace metadata")
      }
      guard page.get(row, "replication") is MapValue(entries) &&
        entries.length() <= config.max_nodes + 1 else {
        raise Unexpected("invalid replication metadata")
      }
      let options : Map[String, String] = Map([])
      for pair in entries {
        guard pair is (Text(key), Text(value)) && !options.contains(key) else {
          raise Unexpected("invalid replication option")
        }
        options[key] = value
      }
      keyspaces[keyspace] = @routing.replication(options)
    }
  }
  {
    revision,
    refreshed_at: @async.now(),
    cluster_name: topology_text(local_page, 0, "cluster_name"),
    partitioner: topology_text(local_page, 0, "partitioner"),
    nodes,
    keyspaces,
  }
}

///|
priv suberror RefreshDue

///|
async fn wait_topology_signal(
  connection : Connection,
  control : ControlState,
) -> Unit {
  let config = control.config
  @async.with_timeout(
    config.refresh_interval_ms,
    () => {
      ignore(connection.next_event())
      control.stale = true
      control.schema_epoch += 1
      @async.sleep(config.debounce_ms)
      // 单一控制任务合并已到达事件，不为每条通知创建刷新任务。
      while connection.events.try_get() is Some(_) {
        ()
      }
    },
    error=RefreshDue,
  ) catch {
    RefreshDue => ()
    error => raise error
  }
}

///|
async fn[G] Session::reconcile(
  self : Session,
  snapshot : TopologySnapshot,
  group : @async.TaskGroup[G],
) -> Unit {
  let desired : Map[String, Endpoint] = Map([])
  for node in snapshot.nodes {
    if node.endpoint is Some(endpoint) {
      let config = endpoint_config(self.config.connection, endpoint)
      config.validate()
      let key = "\{endpoint.host}:\{endpoint.port}"
      if desired.contains(key) {
        raise Configuration("mapped topology endpoints must be unique")
      }
      desired[key] = endpoint
    }
  }
  // 移除前先取消并等待所属任务，旧成员不会留下后台重连。
  let mut index = self.nodes.length() - 1
  while index >= 0 {
    let node = self.nodes[index]
    let keep = desired.get("\{node.endpoint.host}:\{node.endpoint.port}")
      is Some(endpoint) &&
      endpoint.server_name == node.endpoint.server_name
    if !keep {
      node.close_connections()
      if node.worker is Some(worker) {
        worker.cancel()
        @async.protect_from_cancel(() => ignore(worker.wait()) catch { _ => () })
      }
      ignore(self.nodes.remove(index))
    }
    index -= 1
  }
  if self.closed || self.draining {
    return
  }
  for key, endpoint in desired {
    if !self.nodes.any(node => {
        "\{node.endpoint.host}:\{node.endpoint.port}" == key
      }) {
      let node = session_node(
        self.config.connection,
        endpoint,
        self.config.connections_per_node,
      )
      self.nodes.push(node)
      node.worker = Some(
        group.spawn(() => self.maintain(node, group), no_wait=true),
      )
    }
  }
  self.changed.broadcast()
}

///|
async fn[G] Session::maintain_control(
  self : Session,
  control : ControlState,
  group : @async.TaskGroup[G],
) -> Unit {
  let mut next = 0
  let mut backoff = self.config.backoff_initial_ms
  let random = @random.Rand::new()
  while !self.closed && !self.draining {
    let candidates = self.nodes.map(node => node.endpoint)
    if candidates.is_empty() {
      for endpoint in self.config.contact_points {
        candidates.push(endpoint)
      }
      if candidates.is_empty() {
        candidates.push(
          Endpoint::new(
            host=self.config.connection.host,
            port=self.config.connection.port,
          ),
        )
      }
    }
    let endpoint = candidates[next % candidates.length()]
    next += 1
    let mut connected_at = None
    try {
      let connection = match self.pool_for(endpoint) {
        Some(node) => self.connect_pool_node(node, group, None)
        None =>
          connect_observed(
            group,
            endpoint_config(self.config.connection, endpoint),
            None,
            Some(self.admission),
          )
      }
      connected_at = Some(@async.now())
      control.connection = Some(connection)
      defer @async.protect_from_cancel(() => {
        connection.shutdown()
        control.connection = None
        control.stale = true
      })
      connection.register([TopologyChange, StatusChange, SchemaChange])
      control.generation += 1
      if control.generation > 1 &&
        self.config.connection.metrics is Some(metrics) {
        metrics.data.control_reconnects += 1L
        metrics.emit(Reconnected(endpoint, control.generation, true))
      }
      while !self.closed && !self.draining {
        let snapshot = read_topology(
          connection,
          endpoint,
          control.config,
          control.refreshes + 1,
        )
        if control.snapshot is Some(previous) &&
          previous.cluster_name != snapshot.cluster_name {
          raise Configuration("control endpoint belongs to a different cluster")
        }
        self.reconcile(snapshot, group)
        control.ring = @routing.Ring::new(
          snapshot.nodes.map(node => {
            host_id: node.host_id,
            data_center: node.data_center,
            rack: node.rack,
            tokens: node.tokens,
          }),
          snapshot.partitioner,
        )
        let locations : Map[String, (String, Bytes)] = Map([])
        for node in snapshot.nodes {
          if node.endpoint is Some(endpoint) {
            locations["\{endpoint.host}:\{endpoint.port}"] = (
              node.data_center,
              node.host_id,
            )
          }
        }
        control.locations = locations
        control.snapshot = Some(snapshot)
        control.refreshes += 1
        control.stale = false
        control.last_error = None
        wait_topology_signal(connection, control)
      }
    } catch {
      error => {
        control.last_error = Some(error)
        control.stale = true
      }
    }
    if self.closed || self.draining {
      return
    }
    if connected_at is Some(since) &&
      @async.now() - since >= self.config.stable_reset_ms.to_int64() {
      backoff = self.config.backoff_initial_ms
    }
    let candidate = backoff.to_double() *
      (1.0 - self.config.jitter + 2.0 * self.config.jitter * random.double())
    let delay = if candidate < 1.0 {
      1
    } else if candidate > self.config.backoff_max_ms.to_double() {
      self.config.backoff_max_ms
    } else {
      candidate.to_int()
    }
    self.retry_pause(delay)
    backoff = if backoff > self.config.backoff_max_ms / 2 {
      self.config.backoff_max_ms
    } else {
      backoff * 2
    }
  }
}
