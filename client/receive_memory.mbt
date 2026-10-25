///|
/// 按正文逻辑字节观测，不包含 Value 对象、分配器、TLS 或调用方保存的结果。
pub(all) struct ReceiveMemorySnapshot {
  endpoint : Endpoint
  pool_slot : Int
  scope : RpcScope
  reassembling_bytes : Int64
  queued_envelope_bytes : Int64
  delivering_body_bytes : Int64
  peak_wire_bytes : Int64
  peak_delivering_body_bytes : Int64
  decoded_responses : Int64
  discarded_responses : Int64
  decode_ms : Int64
  max_decode_ms : Int64
}

///|
pub fn Connection::receive_memory(self : Connection) -> ReceiveMemorySnapshot {
  {
    endpoint: Endpoint::new(host=self.config.host, port=self.config.port),
    pool_slot: self.pool_slot,
    scope: self.rpc_scope,
    reassembling_bytes: self.wire.decoder.buffered_bytes(),
    queued_envelope_bytes: self.wire.queued_bytes,
    delivering_body_bytes: self.delivery_bytes,
    peak_wire_bytes: self.wire.peak_bytes,
    peak_delivering_body_bytes: self.peak_delivery_bytes,
    decoded_responses: self.decoded_responses,
    discarded_responses: self.discarded_responses,
    decode_ms: self.decode_ms,
    max_decode_ms: self.max_decode_ms,
  }
}

///|
/// 返回当前物理连接的独立快照；连接代次退出后由应用自行归档历史。
pub fn Session::receive_memory(self : Session) -> Array[ReceiveMemorySnapshot] {
  let snapshots = []
  for node in self.nodes {
    for slot in node.slots {
      if slot.current is Some(connection) {
        snapshots.push(connection.receive_memory())
      }
    }
  }
  if self.control is Some(control) && control.connection is Some(connection) {
    snapshots.push(connection.receive_memory())
  }
  snapshots
}

///|
fn Connection::release_delivery(self : Connection, pending : Pending) -> Unit {
  if pending.response_bytes != 0L {
    self.delivery_bytes -= pending.response_bytes
    pending.response_bytes = 0L
  }
}
