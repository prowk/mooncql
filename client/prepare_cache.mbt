///|
struct PreparedCache {
  capacity : Int
  entries : Map[Bytes, Prepared]
  order : Array[Bytes]
  metrics : Metrics?
  endpoint : Endpoint
}

///|
fn PreparedCache::new(config : Config) -> PreparedCache {
  {
    capacity: config.prepared_cache_capacity,
    entries: Map([]),
    order: [],
    metrics: config.metrics,
    endpoint: Endpoint::new(host=config.host, port=config.port),
  }
}

///|
fn PreparedCache::touch(self : PreparedCache, key : Bytes) -> Unit {
  for i in 0..<self.order.length() {
    if self.order[i] == key {
      ignore(self.order.remove(i))
      break
    }
  }
  self.order.push(key)
}

///|
fn PreparedCache::get(self : PreparedCache, key : Bytes) -> Prepared? {
  let value = self.entries.get(key)
  if self.metrics is Some(metrics) {
    metrics.cache(self.endpoint, if value is Some(_) { Hit } else { Miss })
  }
  if value is Some(_) {
    self.touch(key)
  }
  value
}

///|
fn PreparedCache::store(
  self : PreparedCache,
  key : Bytes,
  value : Prepared,
) -> Unit {
  if self.capacity == 0 {
    return
  }
  if !self.entries.contains(key) && self.entries.length() >= self.capacity {
    self.entries.remove(self.order.remove(0))
    if self.metrics is Some(metrics) {
      metrics.cache(self.endpoint, Evicted)
    }
  }
  self.entries[key] = value
  self.touch(key)
}

///|
fn PreparedCache::clear(self : PreparedCache) -> Unit {
  self.entries.clear()
  self.order.clear()
}

///|
struct PrepareFlight {
  mutex : @async.Mutex
  mut users : Int
  mut result : Prepared?
  mut failure : Error?
}

///|
pub fn Connection::prepared_cache_size(self : Connection) -> Int {
  self.prepared_cache.entries.length()
}

///|
fn Connection::prepare_flight(
  self : Connection,
  key : Bytes,
) -> PrepareFlight raise DriverError {
  if self.preparing.get(key) is Some(flight) {
    if self.config.metrics is Some(metrics) {
      metrics.cache(
        Endpoint::new(host=self.config.host, port=self.config.port),
        Coalesced,
      )
    }
    return flight
  }
  let bytes = key.length().to_int64()
  if self.preparing.length().to_int64() >=
    self.config.max_in_flight.to_int64() + self.config.max_waiting.to_int64() {
    raise Overloaded(WaitingQueueFull)
  }
  let limit = self.config.max_in_flight_bytes.to_int64() +
    self.config.max_waiting_bytes.to_int64()
  if self.preparing_bytes + bytes > limit {
    raise Overloaded(WaitingBytesFull)
  }
  let flight = PrepareFlight::{
    mutex: @async.Mutex(),
    users: 0,
    result: None,
    failure: None,
  }
  self.preparing[key] = flight
  self.preparing_bytes += bytes
  flight
}

///|
fn Connection::leave_prepare(
  self : Connection,
  key : Bytes,
  flight : PrepareFlight,
) -> Unit {
  flight.users -= 1
  if flight.users == 0 &&
    self.preparing.get(key) is Some(current) &&
    physical_equal(current, flight) {
    self.preparing.remove(key)
    self.preparing_bytes -= key.length().to_int64()
  }
}
