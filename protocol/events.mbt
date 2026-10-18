///|
pub(all) enum EventKind {
  TopologyChange
  StatusChange
  SchemaChange
} derive(Eq, @debug.Debug)

///|
pub extend EventKind with Eq::{equal, not_equal}

///|
pub extend EventKind with @debug.Debug::{to_repr}

///|
pub(all) enum TopologyChangeKind {
  NewNode
  RemovedNode
  MovedNode
} derive(Eq, @debug.Debug)

///|
pub extend TopologyChangeKind with Eq::{equal, not_equal}

///|
pub extend TopologyChangeKind with @debug.Debug::{to_repr}

///|
pub(all) enum StatusChangeKind {
  Up
  Down
} derive(Eq, @debug.Debug)

///|
pub extend StatusChangeKind with Eq::{equal, not_equal}

///|
pub extend StatusChangeKind with @debug.Debug::{to_repr}

///|
pub(all) enum SchemaChangeKind {
  Created
  Updated
  Dropped
} derive(Eq, @debug.Debug)

///|
pub extend SchemaChangeKind with Eq::{equal, not_equal}

///|
pub extend SchemaChangeKind with @debug.Debug::{to_repr}

///|
pub(all) enum SchemaTarget {
  Keyspace(String)
  Table(String, String)
  Type(String, String)
  Function(String, String, Array[String])
  Aggregate(String, String, Array[String])
} derive(Eq, @debug.Debug)

///|
pub extend SchemaTarget with Eq::{equal, not_equal}

///|
pub extend SchemaTarget with @debug.Debug::{to_repr}

///|
pub(all) struct InetEndpoint {
  address : Bytes
  port : Int
} derive(Eq, @debug.Debug)

///|
pub extend InetEndpoint with Eq::{equal, not_equal}

///|
pub extend InetEndpoint with @debug.Debug::{to_repr}

///|
pub(all) enum ServerEvent {
  Topology(TopologyChangeKind, InetEndpoint)
  Status(StatusChangeKind, InetEndpoint)
  Schema(SchemaChangeKind, SchemaTarget)
} derive(Eq, @debug.Debug)

///|
pub extend ServerEvent with Eq::{equal, not_equal}

///|
pub extend ServerEvent with @debug.Debug::{to_repr}

///|
pub fn register(events : Array[EventKind]) -> Request raise @codec.CodecError {
  if events.is_empty() || events.length() > 3 {
    raise @codec.CodecError("invalid event subscription")
  }
  let seen = []
  let w = @codec.Writer::new()
  w.u16(events.length())
  for event in events {
    if seen.contains(event) {
      raise @codec.CodecError("duplicate event subscription")
    }
    seen.push(event)
    w.string(
      match event {
        TopologyChange => "TOPOLOGY_CHANGE"
        StatusChange => "STATUS_CHANGE"
        SchemaChange => "SCHEMA_CHANGE"
      },
    )
  }
  { opcode: 11, body: w.to_bytes(), }
}

///|
fn read_event_endpoint(
  r : @codec.Reader,
) -> InetEndpoint raise @codec.CodecError {
  let size = r.u8()
  if size != 4 && size != 16 {
    raise @codec.CodecError("invalid event inet address length")
  }
  let address = r.take(size)
  let port = r.i32()
  if port < 0 || port > 65535 {
    raise @codec.CodecError("invalid event inet port")
  }
  { address, port, }
}

///|
pub fn decode_event(body : Bytes) -> ServerEvent raise @codec.CodecError {
  let r = @codec.Reader::new(body)
  let event = match r.string() {
    "TOPOLOGY_CHANGE" => {
      let change = match r.string() {
        "NEW_NODE" => NewNode
        "REMOVED_NODE" => RemovedNode
        "MOVED_NODE" => MovedNode
        _ => raise @codec.CodecError("unknown topology change")
      }
      Topology(change, read_event_endpoint(r))
    }
    "STATUS_CHANGE" => {
      let change = match r.string() {
        "UP" => Up
        "DOWN" => Down
        _ => raise @codec.CodecError("unknown status change")
      }
      Status(change, read_event_endpoint(r))
    }
    "SCHEMA_CHANGE" => {
      let change = match r.string() {
        "CREATED" => Created
        "UPDATED" => Updated
        "DROPPED" => Dropped
        _ => raise @codec.CodecError("unknown schema change")
      }
      let target = r.string()
      let keyspace = r.string()
      let target = match target {
        "KEYSPACE" => Keyspace(keyspace)
        "TABLE" => Table(keyspace, r.string())
        "TYPE" => Type(keyspace, r.string())
        "FUNCTION" | "AGGREGATE" => {
          let name = r.string()
          let count = r.u16()
          // 每个字符串至少有两字节长度，先检查后分配。
          if count > r.remaining() / 2 {
            raise @codec.CodecError("invalid schema argument count")
          }
          let arguments = []
          for _ in 0..<count {
            arguments.push(r.string())
          }
          if target == "FUNCTION" {
            Function(keyspace, name, arguments)
          } else {
            Aggregate(keyspace, name, arguments)
          }
        }
        _ => raise @codec.CodecError("unknown schema event target")
      }
      Schema(change, target)
    }
    _ => raise @codec.CodecError("unknown event type")
  }
  r.finish()
  event
}
