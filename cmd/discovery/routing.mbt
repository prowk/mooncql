///|
async fn verify_routing(session : @client.Session, directory : String) -> Unit {
  @fs.write_file("\{directory}/stage", "create-routing-keyspaces\n")
  let keyspaces = ["mooncql_routing_simple", "mooncql_routing_nts"]
  ignore(
    session.query(
      "CREATE KEYSPACE IF NOT EXISTS mooncql_routing_simple WITH replication = {'class':'SimpleStrategy','replication_factor':1}",
    ),
  )
  ignore(
    session.query(
      "CREATE KEYSPACE IF NOT EXISTS mooncql_routing_nts WITH replication = {'class':'NetworkTopologyStrategy','dc1':2}",
    ),
  )
  for keyspace in keyspaces {
    ignore(
      session.query(
        "CREATE TABLE IF NOT EXISTS \{keyspace}.probe (id blob PRIMARY KEY,value int)",
      ),
    )
  }
  @fs.write_file("\{directory}/stage", "await-routing-schema\n")
  @async.with_timeout(60000, () => {
    while true {
      if session.topology() is Some(snapshot) &&
        keyspaces.all(keyspace => snapshot.keyspaces.contains(keyspace)) &&
        !session.control_status().unwrap().stale &&
        snapshot.nodes.all(node => {
          node.schema_version == snapshot.nodes[0].schema_version
        }) {
        break
      }
      @async.sleep(20)
    }
  })
  // 等待同一次 DDL 的多条通知排空，随后在稳定元数据下核对实际协调节点。
  @async.sleep(300)
  let snapshot = session.topology().unwrap()
  let ring = @routing.Ring::new(
    snapshot.nodes.map(node => {
      host_id: node.host_id,
      data_center: node.data_center,
      rack: node.rack,
      tokens: node.tokens,
    }),
    snapshot.partitioner,
  ).unwrap()
  let records = []
  let options = @protocol.QueryOptions::new(consistency=Quorum)
  @fs.write_file("\{directory}/stage", "verify-routing-requests\n")
  for keyspace in keyspaces {
    for id in 0..<32 {
      let key = @types.encode_scalar(Integer(id))
      let token = @routing.murmur3_token(key)
      let hint = @client.RoutingHint::new(keyspace, key)
      ignore(
        session.query(
          "INSERT INTO \{keyspace}.probe (id,value) VALUES (?,?)",
          values=[Bytes(key), Integer(id)],
          routing=hint,
          options~,
        ),
      )
      guard session.query(
          "SELECT value,token(id) AS routing_token FROM \{keyspace}.probe WHERE id=?",
          values=[Bytes(key)],
          routing=hint,
          options~,
        )
        is Rows(page) else {
        fail("missing routed row")
      }
      assert_eq(page.get(0, "value"), @types.Value::Integer(id))
      assert_eq(page.get(0, "routing_token"), @types.Value::BigInteger(token))
      guard session.query("SELECT host_id FROM system.local", routing=hint)
        is Rows(coordinator) else {
        fail("missing coordinator")
      }
      guard coordinator.get(0, "host_id") is Uuid(host_id) else {
        fail("missing coordinator UUID")
      }
      let replicas = ring.replicas(token, snapshot.keyspaces[keyspace]).unwrap()
      assert_true(replicas.contains(host_id))
      let ids = replicas.map(replica => "\"\{@hex.encode(replica)}\"")
      records.push(
        "{\"keyspace\":\"\{keyspace}\",\"key\":\"\{@hex.encode(key)}\",\"token\":\{token},\"replicas\":[\{ids.join(",")}],\"coordinator\":\"\{@hex.encode(host_id)}\"}",
      )
    }
  }
  @fs.write_file("\{directory}/routing.json", "[\{records.join(",")}]\n")
  println(
    "PASS 64 real token values, replica-coordinator choices, RF=1 SimpleStrategy and RF=2 NetworkTopologyStrategy",
  )
}
