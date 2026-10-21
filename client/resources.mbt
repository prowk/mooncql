///|
pub(all) struct SessionResources {
  active : Int
  pending : Int
  abandoned : Int
  in_flight : Int
  in_flight_bytes : Int64
  waiting : Int
  waiting_bytes : Int64
  cache_sizes : Array[Int]
  background_task_handles : Int
} derive(@debug.Debug, ToJson)

///|
pub extend SessionResources with @debug.Debug::{to_repr}

///|
pub extend SessionResources with ToJson::{to_json}

///|
pub fn Session::resources(self : Session) -> SessionResources {
  let connections = []
  let mut handles = 0
  for node in self.nodes {
    if node.worker is Some(_) {
      handles += 1
    }
    if node.current is Some(connection) {
      connections.push(connection)
    }
  }
  if self.control is Some(control) {
    if control.worker is Some(_) {
      handles += 1
    }
    if control.connection is Some(connection) {
      connections.push(connection)
    }
  }
  let mut pending = 0
  let mut abandoned = 0
  let mut in_flight = 0
  let mut in_flight_bytes = 0L
  let mut waiting = self.waiting
  let mut waiting_bytes = self.waiting_bytes
  let cache_sizes = []
  for connection in connections {
    pending += connection.pending_count()
    abandoned += connection.abandoned_count()
    in_flight += connection.in_flight_count()
    in_flight_bytes += connection.in_flight_bytes()
    waiting += connection.waiting_count()
    waiting_bytes += connection.waiting_bytes()
    cache_sizes.push(connection.prepared_cache_size())
    if connection.reader_task is Some(_) {
      handles += 1
    }
    if connection.reaper_task is Some(_) {
      handles += 1
    }
    if connection.health_task is Some(_) {
      handles += 1
    }
  }
  {
    active: self.active,
    pending,
    abandoned,
    in_flight,
    in_flight_bytes,
    waiting,
    waiting_bytes,
    cache_sizes,
    background_task_handles: handles,
  }
}
