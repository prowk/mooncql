///|
fn node_id(index : Int) -> Bytes {
  Bytes::from_array(
    Array::makei(16, i => if i == 15 { index.to_byte() } else { b'\x00' }),
  )
}

///|
test "replicas match independent Simple and NetworkTopology strategies across ring boundaries" {
  let nodes : Array[@routing.Node] = [
    { host_id: node_id(0), data_center: "dc1", rack: "r1", tokens: [-80L, 0L], },
    { host_id: node_id(1), data_center: "dc1", rack: "r1", tokens: [-50L], },
    { host_id: node_id(2), data_center: "dc1", rack: "r2", tokens: [20L], },
    {
      host_id: node_id(3),
      data_center: "dc2",
      rack: "r1",
      tokens: [-20L, 90L],
    },
    { host_id: node_id(4), data_center: "dc2", rack: "r2", tokens: [40L], },
    { host_id: node_id(5), data_center: "dc2", rack: "r3", tokens: [80L], },
  ]
  let ring = @routing.Ring::new(
    nodes, "org.apache.cassandra.dht.Murmur3Partitioner",
  ).unwrap()
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "1"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(-100L, strategy).unwrap()
    let expected = [node_id(0)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "1"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(-80L, strategy).unwrap()
    let expected = [node_id(0)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "1"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(-79L, strategy).unwrap()
    let expected = [node_id(1)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "1"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(-20L, strategy).unwrap()
    let expected = [node_id(3)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "1"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(-19L, strategy).unwrap()
    let expected = [node_id(0)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "1"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(0L, strategy).unwrap()
    let expected = [node_id(0)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "1"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(1L, strategy).unwrap()
    let expected = [node_id(2)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "1"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(50L, strategy).unwrap()
    let expected = [node_id(5)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "1"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(90L, strategy).unwrap()
    let expected = [node_id(3)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "1"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(99L, strategy).unwrap()
    let expected = [node_id(0)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "1"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(100L, strategy).unwrap()
    let expected = [node_id(0)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "2"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(-100L, strategy).unwrap()
    let expected = [node_id(0), node_id(1)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "2"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(-80L, strategy).unwrap()
    let expected = [node_id(0), node_id(1)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "2"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(-79L, strategy).unwrap()
    let expected = [node_id(1), node_id(3)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "2"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(-20L, strategy).unwrap()
    let expected = [node_id(0), node_id(3)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "2"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(-19L, strategy).unwrap()
    let expected = [node_id(0), node_id(2)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "2"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(0L, strategy).unwrap()
    let expected = [node_id(0), node_id(2)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "2"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(1L, strategy).unwrap()
    let expected = [node_id(2), node_id(4)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "2"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(50L, strategy).unwrap()
    let expected = [node_id(3), node_id(5)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "2"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(90L, strategy).unwrap()
    let expected = [node_id(0), node_id(3)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "2"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(99L, strategy).unwrap()
    let expected = [node_id(0), node_id(1)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "2"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(100L, strategy).unwrap()
    let expected = [node_id(0), node_id(1)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "4"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(-100L, strategy).unwrap()
    let expected = [node_id(0), node_id(1), node_id(2), node_id(3)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "4"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(-80L, strategy).unwrap()
    let expected = [node_id(0), node_id(1), node_id(2), node_id(3)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "4"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(-79L, strategy).unwrap()
    let expected = [node_id(0), node_id(1), node_id(2), node_id(3)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "4"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(-20L, strategy).unwrap()
    let expected = [node_id(0), node_id(2), node_id(3), node_id(4)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "4"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(-19L, strategy).unwrap()
    let expected = [node_id(0), node_id(2), node_id(4), node_id(5)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "4"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(0L, strategy).unwrap()
    let expected = [node_id(0), node_id(2), node_id(4), node_id(5)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "4"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(1L, strategy).unwrap()
    let expected = [node_id(2), node_id(3), node_id(4), node_id(5)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "4"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(50L, strategy).unwrap()
    let expected = [node_id(0), node_id(1), node_id(3), node_id(5)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "4"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(90L, strategy).unwrap()
    let expected = [node_id(0), node_id(1), node_id(2), node_id(3)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "4"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(99L, strategy).unwrap()
    let expected = [node_id(0), node_id(1), node_id(2), node_id(3)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "4"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(100L, strategy).unwrap()
    let expected = [node_id(0), node_id(1), node_id(2), node_id(3)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "99"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(-100L, strategy).unwrap()
    let expected = [
      node_id(0),
      node_id(1),
      node_id(2),
      node_id(3),
      node_id(4),
      node_id(5),
    ]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "99"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(-80L, strategy).unwrap()
    let expected = [
      node_id(0),
      node_id(1),
      node_id(2),
      node_id(3),
      node_id(4),
      node_id(5),
    ]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "99"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(-79L, strategy).unwrap()
    let expected = [
      node_id(0),
      node_id(1),
      node_id(2),
      node_id(3),
      node_id(4),
      node_id(5),
    ]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "99"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(-20L, strategy).unwrap()
    let expected = [
      node_id(0),
      node_id(1),
      node_id(2),
      node_id(3),
      node_id(4),
      node_id(5),
    ]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "99"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(-19L, strategy).unwrap()
    let expected = [
      node_id(0),
      node_id(1),
      node_id(2),
      node_id(3),
      node_id(4),
      node_id(5),
    ]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "99"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(0L, strategy).unwrap()
    let expected = [
      node_id(0),
      node_id(1),
      node_id(2),
      node_id(3),
      node_id(4),
      node_id(5),
    ]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "99"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(1L, strategy).unwrap()
    let expected = [
      node_id(0),
      node_id(1),
      node_id(2),
      node_id(3),
      node_id(4),
      node_id(5),
    ]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "99"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(50L, strategy).unwrap()
    let expected = [
      node_id(0),
      node_id(1),
      node_id(2),
      node_id(3),
      node_id(4),
      node_id(5),
    ]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "99"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(90L, strategy).unwrap()
    let expected = [
      node_id(0),
      node_id(1),
      node_id(2),
      node_id(3),
      node_id(4),
      node_id(5),
    ]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "99"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(99L, strategy).unwrap()
    let expected = [
      node_id(0),
      node_id(1),
      node_id(2),
      node_id(3),
      node_id(4),
      node_id(5),
    ]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("replication_factor", "99"), ("class", "SimpleStrategy")]),
    )
    let actual = ring.replicas(100L, strategy).unwrap()
    let expected = [
      node_id(0),
      node_id(1),
      node_id(2),
      node_id(3),
      node_id(4),
      node_id(5),
    ]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("dc1", "2"), ("dc2", "1"), ("class", "NetworkTopologyStrategy")]),
    )
    let actual = ring.replicas(-100L, strategy).unwrap()
    let expected = [node_id(0), node_id(2), node_id(3)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("dc1", "2"), ("dc2", "1"), ("class", "NetworkTopologyStrategy")]),
    )
    let actual = ring.replicas(-80L, strategy).unwrap()
    let expected = [node_id(0), node_id(2), node_id(3)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("dc1", "2"), ("dc2", "1"), ("class", "NetworkTopologyStrategy")]),
    )
    let actual = ring.replicas(-79L, strategy).unwrap()
    let expected = [node_id(1), node_id(2), node_id(3)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("dc1", "2"), ("dc2", "1"), ("class", "NetworkTopologyStrategy")]),
    )
    let actual = ring.replicas(-20L, strategy).unwrap()
    let expected = [node_id(0), node_id(2), node_id(3)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("dc1", "2"), ("dc2", "1"), ("class", "NetworkTopologyStrategy")]),
    )
    let actual = ring.replicas(-19L, strategy).unwrap()
    let expected = [node_id(0), node_id(2), node_id(4)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("dc1", "2"), ("dc2", "1"), ("class", "NetworkTopologyStrategy")]),
    )
    let actual = ring.replicas(0L, strategy).unwrap()
    let expected = [node_id(0), node_id(2), node_id(4)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("dc1", "2"), ("dc2", "1"), ("class", "NetworkTopologyStrategy")]),
    )
    let actual = ring.replicas(1L, strategy).unwrap()
    let expected = [node_id(0), node_id(2), node_id(4)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("dc1", "2"), ("dc2", "1"), ("class", "NetworkTopologyStrategy")]),
    )
    let actual = ring.replicas(50L, strategy).unwrap()
    let expected = [node_id(0), node_id(2), node_id(5)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("dc1", "2"), ("dc2", "1"), ("class", "NetworkTopologyStrategy")]),
    )
    let actual = ring.replicas(90L, strategy).unwrap()
    let expected = [node_id(0), node_id(2), node_id(3)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("dc1", "2"), ("dc2", "1"), ("class", "NetworkTopologyStrategy")]),
    )
    let actual = ring.replicas(99L, strategy).unwrap()
    let expected = [node_id(0), node_id(2), node_id(3)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("dc1", "2"), ("dc2", "1"), ("class", "NetworkTopologyStrategy")]),
    )
    let actual = ring.replicas(100L, strategy).unwrap()
    let expected = [node_id(0), node_id(2), node_id(3)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("dc1", "3"), ("dc2", "2"), ("class", "NetworkTopologyStrategy")]),
    )
    let actual = ring.replicas(-100L, strategy).unwrap()
    let expected = [node_id(0), node_id(1), node_id(2), node_id(3), node_id(4)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("dc1", "3"), ("dc2", "2"), ("class", "NetworkTopologyStrategy")]),
    )
    let actual = ring.replicas(-80L, strategy).unwrap()
    let expected = [node_id(0), node_id(1), node_id(2), node_id(3), node_id(4)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("dc1", "3"), ("dc2", "2"), ("class", "NetworkTopologyStrategy")]),
    )
    let actual = ring.replicas(-79L, strategy).unwrap()
    let expected = [node_id(0), node_id(1), node_id(2), node_id(3), node_id(4)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("dc1", "3"), ("dc2", "2"), ("class", "NetworkTopologyStrategy")]),
    )
    let actual = ring.replicas(-20L, strategy).unwrap()
    let expected = [node_id(0), node_id(1), node_id(2), node_id(3), node_id(4)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("dc1", "3"), ("dc2", "2"), ("class", "NetworkTopologyStrategy")]),
    )
    let actual = ring.replicas(-19L, strategy).unwrap()
    let expected = [node_id(0), node_id(1), node_id(2), node_id(4), node_id(5)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("dc1", "3"), ("dc2", "2"), ("class", "NetworkTopologyStrategy")]),
    )
    let actual = ring.replicas(0L, strategy).unwrap()
    let expected = [node_id(0), node_id(1), node_id(2), node_id(4), node_id(5)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("dc1", "3"), ("dc2", "2"), ("class", "NetworkTopologyStrategy")]),
    )
    let actual = ring.replicas(1L, strategy).unwrap()
    let expected = [node_id(0), node_id(1), node_id(2), node_id(4), node_id(5)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("dc1", "3"), ("dc2", "2"), ("class", "NetworkTopologyStrategy")]),
    )
    let actual = ring.replicas(50L, strategy).unwrap()
    let expected = [node_id(0), node_id(1), node_id(2), node_id(3), node_id(5)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("dc1", "3"), ("dc2", "2"), ("class", "NetworkTopologyStrategy")]),
    )
    let actual = ring.replicas(90L, strategy).unwrap()
    let expected = [node_id(0), node_id(1), node_id(2), node_id(3), node_id(4)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("dc1", "3"), ("dc2", "2"), ("class", "NetworkTopologyStrategy")]),
    )
    let actual = ring.replicas(99L, strategy).unwrap()
    let expected = [node_id(0), node_id(1), node_id(2), node_id(3), node_id(4)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("dc1", "3"), ("dc2", "2"), ("class", "NetworkTopologyStrategy")]),
    )
    let actual = ring.replicas(100L, strategy).unwrap()
    let expected = [node_id(0), node_id(1), node_id(2), node_id(3), node_id(4)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("dc1", "5"), ("dc2", "0"), ("class", "NetworkTopologyStrategy")]),
    )
    let actual = ring.replicas(-100L, strategy).unwrap()
    let expected = [node_id(0), node_id(1), node_id(2)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("dc1", "5"), ("dc2", "0"), ("class", "NetworkTopologyStrategy")]),
    )
    let actual = ring.replicas(-80L, strategy).unwrap()
    let expected = [node_id(0), node_id(1), node_id(2)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("dc1", "5"), ("dc2", "0"), ("class", "NetworkTopologyStrategy")]),
    )
    let actual = ring.replicas(-79L, strategy).unwrap()
    let expected = [node_id(0), node_id(1), node_id(2)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("dc1", "5"), ("dc2", "0"), ("class", "NetworkTopologyStrategy")]),
    )
    let actual = ring.replicas(-20L, strategy).unwrap()
    let expected = [node_id(0), node_id(1), node_id(2)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("dc1", "5"), ("dc2", "0"), ("class", "NetworkTopologyStrategy")]),
    )
    let actual = ring.replicas(-19L, strategy).unwrap()
    let expected = [node_id(0), node_id(1), node_id(2)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("dc1", "5"), ("dc2", "0"), ("class", "NetworkTopologyStrategy")]),
    )
    let actual = ring.replicas(0L, strategy).unwrap()
    let expected = [node_id(0), node_id(1), node_id(2)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("dc1", "5"), ("dc2", "0"), ("class", "NetworkTopologyStrategy")]),
    )
    let actual = ring.replicas(1L, strategy).unwrap()
    let expected = [node_id(0), node_id(1), node_id(2)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("dc1", "5"), ("dc2", "0"), ("class", "NetworkTopologyStrategy")]),
    )
    let actual = ring.replicas(50L, strategy).unwrap()
    let expected = [node_id(0), node_id(1), node_id(2)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("dc1", "5"), ("dc2", "0"), ("class", "NetworkTopologyStrategy")]),
    )
    let actual = ring.replicas(90L, strategy).unwrap()
    let expected = [node_id(0), node_id(1), node_id(2)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  {
    let strategy = @routing.replication(
      Map([("dc1", "5"), ("dc2", "0"), ("class", "NetworkTopologyStrategy")]),
    )
    let actual = ring.replicas(99L, strategy).unwrap()
    let expected = [node_id(0), node_id(1), node_id(2)]
    assert_eq(actual.length(), expected.length())
    assert_true(expected.all(id => actual.contains(id)))
  }
  let strategy = @routing.replication(
    Map([("dc1", "5"), ("dc2", "0"), ("class", "NetworkTopologyStrategy")]),
  )
  let actual = ring.replicas(100L, strategy).unwrap()
  let expected = [node_id(0), node_id(1), node_id(2)]
  assert_eq(actual.length(), expected.length())
  assert_true(expected.all(id => actual.contains(id)))
}

///|
test "unsupported replication partitioner and conflicting metadata fall back safely" {
  let nodes : Array[@routing.Node] = [
    { host_id: node_id(0), data_center: "dc1", rack: "r1", tokens: [0L], },
  ]
  assert_true(
    @routing.Ring::new(nodes, "org.apache.cassandra.dht.RandomPartitioner")
    is None,
  )
  assert_true(
    @routing.Ring::new(
      [nodes[0], { ..nodes[0], host_id: node_id(1), }],
      "org.apache.cassandra.dht.Murmur3Partitioner",
    )
    is None,
  )
  let ring = @routing.Ring::new(
    nodes, "org.apache.cassandra.dht.Murmur3Partitioner",
  ).unwrap()
  for
    options in [
      Map([("class", "LocalStrategy")]),
      Map([("class", "SimpleStrategy"), ("replication_factor", "3/1")]),
      Map([("class", "NetworkTopologyStrategy"), ("dc1", "3/1")]),
      Map([("class", "SimpleStrategy"), ("replication_factor", "0")]),
    ] {
    assert_true(ring.replicas(0L, @routing.replication(options)) is None)
  }
  assert_true(ring.replicas(0L, NetworkTopology(Map([("absent", 3)]))) is None)
}
