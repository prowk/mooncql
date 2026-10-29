///|
pub(all) struct RoutingConfig {
  local_dc : String
  allow_remote : Bool
  max_metadata_age_ms : Int32
}

///|
pub fn RoutingConfig::new(
  local_dc : String,
  allow_remote~ : Bool = false,
  max_metadata_age_ms~ : Int32 = 60000,
) -> RoutingConfig {
  { local_dc, allow_remote, max_metadata_age_ms, }
}

///|
pub(all) struct RoutingHint {
  keyspace : String
  key : Bytes
}

///|
pub fn RoutingHint::new(keyspace : String, key : Bytes) -> RoutingHint {
  { keyspace, key, }
}

///|
fn Session::plan_indices(
  self : Session,
  hint : RoutingHint?,
  attempted : Array[String],
) -> Array[Int32] {
  if self.closed {
    return []
  }
  let replicas : Map[Bytes, Bool] = Map([])
  if self.config.routing is Some(config) &&
    self.control is Some(control) &&
    !control.stale &&
    control.snapshot is Some(snapshot) &&
    @async.now() - snapshot.refreshed_at <=
    config.max_metadata_age_ms.to_int64() &&
    control.ring is Some(ring) &&
    hint is Some(hint) &&
    snapshot.keyspaces.get(hint.keyspace) is Some(replication) {
    if ring.replicas(@routing.murmur3_token(hint.key), replication)
      is Some(nodes) {
      for id in nodes {
        replicas[id] = true
      }
    }
  }
  let tiers : Array[Array[Int32]] = Array::makei(8, _ => [])
  for offset in 0..<self.nodes.length() {
    let index = (self.next_node + offset) % self.nodes.length()
    let node = self.nodes[index]
    guard node.representative() is Some(_) else { continue }
    let key = "\{node.endpoint.host}:\{node.endpoint.port}"
    let location = match self.control {
      Some(control) => control.locations.get(key)
      None => None
    }
    let is_local = match self.config.routing {
      Some(config) => location is Some((dc, _)) && dc == config.local_dc
      None => true
    }
    if !is_local && self.config.routing is Some(config) && !config.allow_remote {
      continue
    }
    let replica = location is Some((_, id)) && replicas.contains(id)
    let tier = (if is_local { 0 } else { 2 }) +
      (if replica { 0 } else { 1 }) +
      (if attempted.contains(key) { 4 } else { 0 })
    tiers[tier].push(index)
  }
  let plan = []
  for tier in tiers {
    for index in tier {
      plan.push(index)
    }
  }
  plan
}

///|
pub fn Session::query_plan(
  self : Session,
  hint? : RoutingHint,
) -> Array[Endpoint] {
  self.plan_indices(hint, []).map(index => self.nodes[index].endpoint)
}
