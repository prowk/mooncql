///|
struct Histogram {
  bounds : Array[Int64]
  buckets : Array[Int64]
  mut count : Int64
  mut sum_ms : Int64
}

///|
fn Histogram::new() -> Histogram {
  let bounds = [0L, 1L, 5L, 10L, 25L, 50L, 100L, 250L, 500L, 1000L, 5000L]
  { bounds, buckets: Array::make(bounds.length(), 0L), count: 0L, sum_ms: 0L, }
}

///|
fn Histogram::observe(self : Histogram, duration : Int64) -> Unit {
  let duration = if duration < 0L { 0L } else { duration }
  self.count += 1L
  self.sum_ms += duration
  for index, bound in self.bounds {
    if duration <= bound {
      self.buckets[index] += 1L
    }
  }
}

///|
fn Histogram::write(
  self : Histogram,
  lines : Array[String],
  name : String,
  labels : String,
) -> Unit {
  for index, bound in self.bounds {
    lines.push(
      "\{name}_bucket{\{labels},le=\"\{bound.to_double() / 1000.0}\"} \{self.buckets[index]}",
    )
  }
  lines.push("\{name}_bucket{\{labels},le=\"+Inf\"} \{self.count}")
  lines.push("\{name}_count{\{labels}} \{self.count}")
  lines.push("\{name}_sum{\{labels}} \{self.sum_ms.to_double() / 1000.0}")
}

///|
fn outcome_index(outcome : @client.RequestOutcome) -> Int {
  match outcome {
    Succeeded => 0
    ServerError(0x2500) => 2
    ServerError(_) => 1
    Timeout(_) => 3
    Cancelled => 4
    LocalOverload(_) => 5
    Disconnected => 6
    InvalidConfiguration => 7
    TlsError => 8
    ProtocolError => 9
    TransportError => 10
    OtherFailure => 11
    AuthenticationError => 12
  }
}

///|
fn outcome_names() -> Array[String] {
  [
    "success", "server_error", "unprepared", "timeout", "cancelled", "overload",
    "disconnected", "configuration", "tls", "protocol", "transport", "other", "authentication",
  ]
}

///|
fn operation_index(kind : @client.OperationKind) -> Int {
  match kind {
    QueryOperation => 0
    PrepareOperation => 1
    ExecuteOperation => 2
    BatchOperation => 3
    RequestOperation => 4
    SchemaCheckOperation => 5
    SchemaWaitOperation => 6
    SchemaMetadataOperation => 7
  }
}

///|
fn opcode_index(opcode : Int) -> Int {
  match opcode {
    7 => 0
    9 => 1
    10 => 2
    13 => 3
    11 => 4
    5 => 5
    _ => 6
  }
}

///|
fn scope_index(scope : @client.RpcScope) -> Int {
  match scope {
    Data => 0
    Control => 1
    Heartbeat => 2
  }
}

///|
fn overload_index(reason : @client.OverloadReason) -> Int {
  match reason {
    InFlightLimit => 0
    ByteLimit => 1
    WaitingQueueFull => 2
    WaitingBytesFull => 3
    RequestTooLarge => 4
    SessionInFlightLimit => 5
    SessionByteLimit => 6
    SessionWaitingQueueFull => 7
    SessionWaitingBytesFull => 8
    SessionRequestTooLarge => 9
  }
}

///|
fn escaped(value : String) -> String {
  value
  .replace(old="\\", new="\\\\")
  .replace(old="\n", new="\\n")
  .replace(old="\"", new="\\\"")
}

///|
struct NodeCounters {
  rpc : Array[Int64]
  possible_sent : Array[Int64]
  queue : Array[Histogram]
  execution : Array[Histogram]
  connects : Array[Int64]
  connect_failures : Array[Int64]
  overloads : Array[Int64]
  mut retries : Int64
}

///|
fn NodeCounters::new() -> NodeCounters {
  {
    rpc: Array::make(3 * 7 * 13, 0L),
    possible_sent: Array::make(3 * 7, 0L),
    queue: Array::makei(3, _ => Histogram::new()),
    execution: Array::makei(3, _ => Histogram::new()),
    connects: Array::make(4, 0L),
    overloads: Array::make(10, 0L),
    connect_failures: Array::make(13, 0L),
    retries: 0L,
  }
}

///|
struct Meter {
  nodes : Map[String, NodeCounters]
  max_nodes : Int
  logical : Array[Int64]
  started : Array[Int64]
  logical_latency : Array[Histogram]
  logical_overloads : Array[Int64]
  waits : Array[Histogram]
  mut overflow_events : Int64
}

///|
fn Meter::new(max_nodes? : Int = 32) -> Meter raise @client.DriverError {
  if max_nodes < 1 || max_nodes > 256 {
    raise @client.Configuration("max_nodes must be 1-256")
  }
  {
    nodes: Map([]),
    max_nodes,
    logical: Array::make(8 * 13, 0L),
    started: Array::make(8, 0L),
    logical_latency: Array::makei(8, _ => Histogram::new()),
    logical_overloads: Array::make(10, 0L),
    waits: Array::makei(3, _ => Histogram::new()),
    overflow_events: 0L,
  }
}

///|
fn Meter::node_key(self : Meter, endpoint : @client.Endpoint) -> String {
  let key = "\{endpoint.host}:\{endpoint.port}"
  if self.nodes.contains(key) {
    return key
  }
  let named = self.nodes.length() -
    (if self.nodes.contains("other") { 1 } else { 0 })
  // 不按节点替换次数累积标签；超出上限的节点统一汇总到固定 other。
  if key.length() > 256 || named >= self.max_nodes {
    "other"
  } else {
    key
  }
}

///|
fn Meter::node(
  self : Meter,
  endpoint : @client.Endpoint,
  event? : Bool = true,
) -> NodeCounters {
  let key = self.node_key(endpoint)
  if event && key == "other" {
    self.overflow_events += 1L
  }
  match self.nodes.get(key) {
    Some(node) => node
    None => {
      let node = NodeCounters::new()
      self.nodes[key] = node
      node
    }
  }
}

///|
fn Meter::observe(self : Meter, event : @client.MetricEvent) -> Unit {
  match event {
    OperationStarted(kind) => self.started[operation_index(kind)] += 1L
    OperationFinished(operation) => {
      let kind = operation_index(operation.kind)
      self.logical[kind * 13 + outcome_index(operation.outcome)] += 1L
      self.logical_latency[kind].observe(operation.elapsed_ms)
      if operation.outcome is LocalOverload(reason) {
        self.logical_overloads[overload_index(reason)] += 1L
      }
    }
    RequestFinished(request) => {
      let node = self.node(request.endpoint)
      let scope = scope_index(request.scope)
      node.rpc[(scope * 7 + opcode_index(request.opcode)) * 13 +
      outcome_index(request.outcome)] += 1L
      if request.may_have_been_sent {
        node.possible_sent[scope * 7 + opcode_index(request.opcode)] += 1L
      }
      node.queue[scope].observe(request.queue_ms)
      node.execution[scope].observe(request.execution_ms)
      if request.outcome is LocalOverload(reason) {
        node.overloads[overload_index(reason)] += 1L
      }
    }
    RetryStarted(endpoint, _) => self.node(endpoint).retries += 1L
    WaitFinished(scope, _, duration, _) => {
      let index = match scope {
        Connection => 0
        Prepare => 1
        Retry => 2
      }
      self.waits[index].observe(duration)
    }
    ConnectionAttempt(endpoint) => self.node(endpoint).connects[0] += 1L
    ConnectionEstablished(endpoint) => self.node(endpoint).connects[1] += 1L
    ConnectionFailed(endpoint, outcome) => {
      let node = self.node(endpoint)
      node.connects[2] += 1L
      node.connect_failures[outcome_index(outcome)] += 1L
    }
    ConnectionClosed(endpoint) => self.node(endpoint).connects[3] += 1L
    _ => ()
  }
}

///|
fn Meter::text(self : Meter, session : @client.Session) -> String {
  let lines = [
    "# TYPE mooncql_logical_total counter", "# TYPE mooncql_logical_started_total counter",
    "# TYPE mooncql_rpc_total counter", "# TYPE mooncql_rpc_possible_sent_total counter",
    "# TYPE mooncql_retry_attempts_total counter", "# TYPE mooncql_connections_total counter",
    "# TYPE mooncql_connection_failures_total counter", "# TYPE mooncql_overloads_total counter",
    "# TYPE mooncql_overflow_events_total counter", "# TYPE mooncql_logical_seconds histogram",
    "# TYPE mooncql_rpc_queue_seconds histogram", "# TYPE mooncql_rpc_execution_seconds histogram",
    "# TYPE mooncql_wait_seconds histogram",
  ]
  let base = "session=\"main\""
  let operations = [
    "query", "prepare", "execute", "batch", "request", "schema_check", "schema_wait",
    "schema_metadata",
  ]
  let outcomes = outcome_names()
  let reasons = [
    "in_flight", "bytes", "waiting_count", "waiting_bytes", "request_too_large",
    "session_in_flight", "session_bytes", "session_waiting_count", "session_waiting_bytes",
    "session_request_too_large",
  ]
  for kind, name in operations {
    let labels = "\{base},operation=\"\{name}\""
    lines.push("mooncql_logical_started_total{\{labels}} \{self.started[kind]}")
    for outcome, result in outcomes {
      lines.push(
        "mooncql_logical_total{\{labels},outcome=\"\{result}\"} \{self.logical[kind * 13 + outcome]}",
      )
    }
    self.logical_latency[kind].write(lines, "mooncql_logical_seconds", labels)
  }
  for index, reason in reasons {
    lines.push(
      "mooncql_overloads_total{\{base},scope=\"logical\",reason=\"\{reason}\"} \{self.logical_overloads[index]}",
    )
  }
  let wait_names = ["connection", "prepare", "retry"]
  for index, name in wait_names {
    self.waits[index].write(
      lines,
      "mooncql_wait_seconds",
      "\{base},phase=\"\{name}\"",
    )
  }
  // 资源读当前快照，不用完成事件推测取消后的 stream 或额度是否已释放。
  let gauges : Map[String, Array[Int64]] = Map([])
  for pool in session.pools() {
    ignore(self.node(pool.endpoint, event=false))
    let key = self.node_key(pool.endpoint)
    let values = gauges
      .get(key)
      .unwrap_or_else(() => {
        let values = Array::make(10, 0L)
        gauges[key] = values
        values
      })
    values[0] += pool.ready.to_int64()
    values[1] += pool.connecting.to_int64()
    for connection in pool.connections {
      values[2] += connection.pending.to_int64()
      values[3] += connection.abandoned.to_int64()
      values[4] += connection.available_streams.to_int64()
      values[5] += connection.in_flight.to_int64()
      values[6] += connection.in_flight_bytes
      values[7] += connection.cache_size.to_int64()
      values[8] += connection.waiting.to_int64()
      values[9] += connection.waiting_bytes
    }
  }
  let scopes = ["data", "control", "heartbeat"]
  let opcodes = [
    "query", "prepare", "execute", "batch", "register", "options", "other",
  ]
  let gauge_names = [
    "ready_connections", "connecting", "pending", "abandoned", "available_streams",
    "in_flight", "in_flight_bytes", "prepared_cache_entries", "waiting", "waiting_bytes",
  ]
  for name in gauge_names {
    lines.push("# TYPE mooncql_node_\{name} gauge")
  }
  let keys = self.nodes.keys().to_array()
  keys.sort()
  for key in keys {
    let node = self.nodes[key]
    let labels = "\{base},node=\"\{escaped(key)}\""
    for scope, name in scopes {
      let scoped = "\{labels},scope=\"\{name}\""
      for opcode, operation in opcodes {
        lines.push(
          "mooncql_rpc_possible_sent_total{\{scoped},opcode=\"\{operation}\"} \{node.possible_sent[scope * 7 + opcode]}",
        )
        for outcome, result in outcomes {
          let value = node.rpc[(scope * 7 + opcode) * 13 + outcome]
          if value > 0L {
            lines.push(
              "mooncql_rpc_total{\{scoped},opcode=\"\{operation}\",outcome=\"\{result}\"} \{value}",
            )
          }
        }
      }
      node.queue[scope].write(lines, "mooncql_rpc_queue_seconds", scoped)
      node.execution[scope].write(
        lines, "mooncql_rpc_execution_seconds", scoped,
      )
    }
    lines.push("mooncql_retry_attempts_total{\{labels}} \{node.retries}")
    for index, name in ["attempted", "established", "failed", "closed"] {
      lines.push(
        "mooncql_connections_total{\{labels},event=\"\{name}\"} \{node.connects[index]}",
      )
    }
    for index, name in outcomes {
      if node.connect_failures[index] > 0L {
        lines.push(
          "mooncql_connection_failures_total{\{labels},outcome=\"\{name}\"} \{node.connect_failures[index]}",
        )
      }
    }
    for index, reason in reasons {
      lines.push(
        "mooncql_overloads_total{\{labels},scope=\"rpc\",reason=\"\{reason}\"} \{node.overloads[index]}",
      )
    }
    let gauge = gauges.get(key).unwrap_or_else(() => Array::make(10, 0L))
    for index, name in gauge_names {
      lines.push("mooncql_node_\{name}{\{labels}} \{gauge[index]}")
    }
  }
  lines.push("mooncql_overflow_events_total{\{base}} \{self.overflow_events}")
  let resources = session.resources()
  let budget = session.budget()
  let samples = [
    ("active_operations", session.active_count().to_int64()),
    ("pending", resources.pending.to_int64()),
    ("abandoned", resources.abandoned.to_int64()),
    ("background_tasks", resources.background_task_handles.to_int64()),
    ("in_flight", budget.in_flight.to_int64()),
    ("in_flight_bytes", budget.in_flight_bytes),
    ("waiting", budget.waiting.to_int64()),
    ("waiting_bytes", budget.waiting_bytes),
  ]
  for pair in samples {
    lines.push("# TYPE mooncql_session_\{pair.0} gauge")
    lines.push("mooncql_session_\{pair.0}{\{base}} \{pair.1}")
  }
  lines.join("\n") + "\n"
}
