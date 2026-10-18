///|
pub(all) enum Replication {
  Simple(Int)
  NetworkTopology(Map[String, Int])
  Unsupported(String)
}

///|
pub fn replication(options : Map[String, String]) -> Replication {
  let strategy = options.get("class").unwrap_or("")
  match strategy {
    "org.apache.cassandra.locator.SimpleStrategy" | "SimpleStrategy" => {
      if options.length() != 2 {
        return Unsupported(strategy)
      }
      let factor = options
        .get("replication_factor")
        .map(value => @string.parse_int(value)) catch {
          _ => None
        }
      if factor is Some(value) && value > 0 && value <= 65536 {
        Simple(value)
      } else {
        Unsupported(strategy)
      }
    }
    "org.apache.cassandra.locator.NetworkTopologyStrategy"
    | "NetworkTopologyStrategy" => {
      let factors : Map[String, Int] = Map([])
      for dc, text in options {
        if dc == "class" {
          continue
        }
        let factor = Some(@string.parse_int(text)) catch { _ => None }
        guard factor is Some(factor) &&
          !dc.is_empty() &&
          factor >= 0 &&
          factor <= 65536 else {
          return Unsupported(strategy)
        }
        factors[dc] = factor
      }
      if factors.is_empty() {
        Unsupported(strategy)
      } else {
        NetworkTopology(factors)
      }
    }
    _ => Unsupported(strategy)
  }
}

///|
pub(all) struct Node {
  host_id : Bytes
  data_center : String
  rack : String
  tokens : Array[Int64]
}

///|
struct Entry {
  token : Int64
  node : Int
}

///|
pub struct Ring {
  nodes : Array[Node]
  entries : Array[Entry]
}

///|
pub fn Ring::new(nodes : Array[Node], partitioner : String) -> Ring? {
  if partitioner != "org.apache.cassandra.dht.Murmur3Partitioner" ||
    nodes.is_empty() {
    return None
  }
  let entries = []
  let ids : Map[Bytes, Bool] = Map([])
  let tokens : Map[Int64, Bool] = Map([])
  for index, node in nodes {
    if node.host_id.length() != 16 ||
      node.tokens.is_empty() ||
      node.data_center.is_empty() ||
      node.rack.is_empty() ||
      ids.contains(node.host_id) {
      return None
    }
    ids[node.host_id] = true
    for token in node.tokens {
      if tokens.contains(token) {
        return None
      }
      tokens[token] = true
      entries.push({ token, node: index, })
    }
  }
  entries.sort_by((left, right) => left.token.compare(right.token))
  Some({
    nodes: nodes.map(node => { ..node, tokens: node.tokens.copy(), }),
    entries,
  })
}

///|
priv struct DcReplicas {
  mut left : Int
  mut repeats : Int
  racks : Map[String, Bool]
}

///|
pub fn Ring::replicas(
  self : Ring,
  token : Int64,
  strategy : Replication,
) -> Array[Bytes]? {
  let selected = []
  let seen : Map[Bytes, Bool] = Map([])
  let dcs : Map[String, DcReplicas] = Map([])
  let simple = match strategy {
    Simple(factor) => {
      if factor < 1 || factor > 65536 {
        return None
      }
      if factor > self.nodes.length() {
        self.nodes.length()
      } else {
        factor
      }
    }
    NetworkTopology(factors) => {
      for dc, factor in factors {
        if dc.is_empty() || factor < 0 || factor > 65536 {
          return None
        }
        let members = self.nodes.filter(node => node.data_center == dc)
        let racks : Map[String, Bool] = Map([])
        for node in members {
          racks[node.rack] = true
        }
        if factor > 0 && !members.is_empty() {
          dcs[dc] = {
            left: if factor > members.length() {
              members.length()
            } else {
              factor
            },
            repeats: factor - racks.length(),
            racks: Map([]),
          }
        }
      }
      if dcs.is_empty() {
        return None
      }
      0
    }
    Unsupported(_) => return None
  }
  // 第一个 token >= key token；超出环尾时回绕。二分查找避免逐请求扫描整个环。
  let mut low = 0
  let mut high = self.entries.length()
  while low < high {
    let middle = low + (high - low) / 2
    if self.entries[middle].token < token {
      low = middle + 1
    } else {
      high = middle
    }
  }
  for offset in 0..<self.entries.length() {
    let entry = self.entries[(low + offset) % self.entries.length()]
    let node = self.nodes[entry.node]
    if seen.contains(node.host_id) {
      continue
    }
    if simple > 0 {
      selected.push(node.host_id)
      seen[node.host_id] = true
      if selected.length() == simple {
        return Some(selected)
      }
    } else if dcs.get(node.data_center) is Some(dc) && dc.left > 0 {
      if dc.racks.contains(node.rack) {
        if dc.repeats <= 0 {
          continue
        }
        dc.repeats -= 1
      } else {
        dc.racks[node.rack] = true
      }
      selected.push(node.host_id)
      seen[node.host_id] = true
      dc.left -= 1
      if dcs.values().all(state => state.left == 0) {
        return Some(selected)
      }
    }
  }
  Some(selected)
}

///|
pub fn Replication::snapshot(self : Replication) -> Replication {
  match self {
    NetworkTopology(factors) => {
      let copy : Map[String, Int] = Map([])
      for dc, factor in factors {
        copy[dc] = factor
      }
      NetworkTopology(copy)
    }
    other => other
  }
}
