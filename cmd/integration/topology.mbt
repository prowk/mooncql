///|
async fn verify_topology(config : @client.ConnectionBuilder) -> Unit {
  @client.with_session_builder(
    config=@client.SessionBuilder::new(
      connection=config,
      discovery=@client.DiscoveryConfig::new(refresh_interval_ms=200),
    ),
    session => {
      let snapshot = @async.with_timeout(10000, () => {
        while true {
          if session.topology() is Some(snapshot) {
            return snapshot
          }
          @async.sleep(10)
        } nobreak {
          fail("missing topology snapshot")
        }
      })
      assert_eq(snapshot.nodes.length(), 1)
      assert_eq(snapshot.nodes[0].host_id.length(), 16)
      assert_eq(snapshot.nodes[0].native.port, config.port)
      assert_true(!snapshot.nodes[0].data_center.is_empty())
      assert_true(!snapshot.nodes[0].tokens.is_empty())
      assert_eq(
        snapshot.partitioner,
        "org.apache.cassandra.dht.Murmur3Partitioner",
      )
      assert_true(
        session.query("SELECT release_version FROM system.local") is Rows(_),
      )
      session.close()
      assert_true(!session.control_status().unwrap().connected)
      assert_eq(session.active_count(), 0)
      assert_eq(session.waiting_count(), 0)
      println(
        "PASS real system.local/peers_v2 discovery and scoped control shutdown",
      )
    },
  )
}
