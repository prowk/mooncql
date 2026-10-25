///|
priv struct PoolSlot {
  index : Int
  mut current : Connection?
  mut state : NodeState
  mut generation : Int
  mut attempts : Int
  mut last_error : Error?
  mut worker : @async.Task[Unit]?
}

///|
fn PoolSlot::new(index : Int) -> PoolSlot {
  {
    index,
    current: None,
    state: Connecting,
    generation: 0,
    attempts: 0,
    last_error: None,
    worker: None,
  }
}

///|
fn SessionNode::representative(self : SessionNode) -> Connection? {
  for slot in self.slots {
    if slot.current is Some(connection) && !connection.closed {
      return Some(connection)
    }
  }
  None
}

///|
fn SessionNode::owns(self : SessionNode, connection : Connection) -> Bool {
  self.slots.any(slot => {
    slot.current is Some(current) && physical_equal(current, connection)
  })
}

///|
fn SessionNode::state(self : SessionNode) -> NodeState {
  if self.representative() is Some(_) {
    return Ready
  }
  if self.slots.any(slot => slot.state == Connecting) {
    return Connecting
  }
  if self.slots.any(slot => slot.state != Stopped) {
    return Backoff
  }
  Stopped
}

///|
fn SessionNode::choose(self : SessionNode, bytes : Int64) -> Connection? {
  for offset in 0..<self.slots.length() {
    let index = (self.next_slot + offset) % self.slots.length()
    if self.slots[index].current is Some(connection) &&
      connection.admission.fits(bytes) {
      self.next_slot = (index + 1) % self.slots.length()
      return Some(connection)
    }
  }
  None
}

///|
fn SessionNode::close_connections(self : SessionNode) -> Unit {
  for slot in self.slots {
    if slot.current is Some(connection) {
      connection.close()
    }
  }
}

///|
fn Session::pool_for(self : Session, endpoint : Endpoint) -> SessionNode? {
  for node in self.nodes {
    if node.endpoint.host == endpoint.host &&
      node.endpoint.port == endpoint.port &&
      node.endpoint.server_name == endpoint.server_name {
      return Some(node)
    }
  }
  None
}

///|
// 数据槽与已知节点的控制连接共享串行握手门限，避免故障恢复时同时重建整池。
async fn[G] Session::connect_pool_node(
  self : Session,
  node : SessionNode,
  group : @async.TaskGroup[G],
  slot : PoolSlot?,
) -> Connection {
  let mut owned = false
  defer (if owned { node.connect_gate.release() })
  node.connect_gate.acquire()
  owned = true
  if self.closed {
    raise Closed
  }
  if self.draining {
    raise Draining
  }
  node.connecting += 1
  self.changed.broadcast()
  defer {
    node.connecting -= 1
    self.changed.broadcast()
  }
  if slot is Some(slot) {
    node.attempts += 1
    slot.attempts += 1
  }
  connect_observed(
    group,
    node.config,
    None,
    Some(self.admission),
    response_limits?=self.response_limits,
  )
}

///|
async fn[G] Session::maintain(
  self : Session,
  node : SessionNode,
  group : @async.TaskGroup[G],
) -> Unit {
  // 默认单连接继续使用原节点任务，不额外创建一层槽任务。
  if node.slots.length() == 1 {
    self.maintain_slot(node, node.slots[0], group)
    return
  }
  defer (for slot in node.slots {
    slot.worker = None
  })
  @async.with_task_group(workers => {
    for slot in node.slots {
      slot.worker = Some(
        workers.spawn(() => self.maintain_slot(node, slot, group)),
      )
    }
    for slot in node.slots {
      if slot.worker is Some(worker) {
        worker.wait()
      }
    }
  })
}

///|
pub(all) struct PoolConnectionStatus {
  slot : Int
  state : NodeState
  generation : Int
  attempts : Int
  pending : Int
  abandoned : Int
  available_streams : Int
  in_flight : Int
  in_flight_bytes : Int64
  waiting : Int
  waiting_bytes : Int64
  cache_size : Int
  last_error : Error?
}

///|
pub(all) struct PoolStatus {
  endpoint : Endpoint
  configured_connections : Int
  ready : Int
  connecting : Int
  connections : Array[PoolConnectionStatus]
}

///|
/// 返回每节点与每槽的隔离状态，不暴露物理连接供业务绕过 Session 额度。
pub fn Session::pools(self : Session) -> Array[PoolStatus] {
  self.nodes.map(node => {
    let connections = node.slots.map(slot => {
      let connection = slot.current
      let ready = connection is Some(connection) && !connection.closed
      {
        slot: slot.index,
        state: if self.closed {
          Stopped
        } else if ready {
          Ready
        } else if slot.state == Ready {
          Backoff
        } else {
          slot.state
        },
        generation: slot.generation,
        attempts: slot.attempts,
        pending: connection
        .map(connection => connection.pending_count())
        .unwrap_or(0),
        abandoned: connection
        .map(connection => connection.abandoned_count())
        .unwrap_or(0),
        available_streams: if ready {
          32768 - connection.unwrap().pending_count()
        } else {
          0
        },
        in_flight: connection
        .map(connection => connection.in_flight_count())
        .unwrap_or(0),
        in_flight_bytes: connection
        .map(connection => connection.in_flight_bytes())
        .unwrap_or(0L),
        waiting: connection
        .map(connection => connection.waiting_count())
        .unwrap_or(0),
        waiting_bytes: connection
        .map(connection => connection.waiting_bytes())
        .unwrap_or(0L),
        cache_size: connection
        .map(connection => connection.prepared_cache_size())
        .unwrap_or(0),
        last_error: slot.last_error,
      }
    })
    {
      endpoint: node.endpoint,
      configured_connections: node.slots.length(),
      ready: connections.filter(slot => slot.state == Ready).length(),
      connecting: node.connecting,
      connections,
    }
  })
}
