///|
async fn unauthorized(action : async () -> Unit) -> Unit {
  assert_true(
    try {
      action()
      false
    } catch {
      @client.Server(error) => error.code == 0x2100
      _ => false
    },
  )
}

///|
async fn main {
  let identity = match @env.get_env_var("CQL_TLS_CLIENT_THUMBPRINT") {
    Some(thumbprint) => Some(@client.ClientIdentity::WindowsStore(thumbprint))
    None =>
      match @env.get_env_var("CQL_TLS_CLIENT_CERT") {
        Some(cert) =>
          Some(
            @client.ClientIdentity::Pem(
              cert,
              @env.get_env_var("CQL_TLS_CLIENT_KEY").unwrap(),
            ),
          )
        None => None
      }
  }
  let port = @string.parse_int(@env.get_env_var("CQL_PORT").unwrap_or("19064"))
  let connection = @client.Config::new(
    port~,
    username=@env.get_env_var("CQL_USERNAME").unwrap(),
    password=@env.get_env_var("CQL_PASSWORD").unwrap(),
    compression=@env.get_env_var("CQL_COMPRESSION") == Some("lz4"),
    tls=@client.TlsConfig::new(
      ca_file=@env.get_env_var("CQL_TLS_CA").unwrap(),
      server_name="localhost",
      identity?,
    ),
  )
  @client.with_session(config=@client.SessionConfig::new(connection~), session => {
    let insert = session.prepare(
      "INSERT INTO mooncql_permissions.business (id,value) VALUES (?,?)",
    )
    ignore(insert.execute([Integer(42), Text("least privilege")]))
    guard session.query(
        "SELECT id,value FROM mooncql_permissions.business WHERE id=42",
      )
      is Rows(page) else {
      fail("missing business row")
    }
    assert_eq(page.row(0).int("id"), 42)
    assert_eq(page.row(0).text("value"), "least privilege")
    unauthorized(() => {
      ignore(session.query("SELECT * FROM mooncql_permissions.private_data"))
    })
    unauthorized(() => {
      ignore(
        session.query(
          "CREATE TABLE mooncql_permissions.forbidden (id int PRIMARY KEY)",
        ),
      )
    })
    // Cassandra 5.0.5 把这些系统资源固定为认证后可读，不能把 REVOKE 当成拒绝读取。
    let schema = session.schema_metadata(
      options=@client.SchemaOptions::new(keyspaces=["mooncql_permissions"]),
    )
    assert_true(schema.tables().any(table => table.name == "business"))
    assert_true(
      session.query("SELECT release_version FROM system.local") is Rows(_),
    )
    ignore(session.drain(@client.Deadline::after(5000)))
    assert_eq(session.resources().background_task_handles, 0)
    assert_eq(session.budget().in_flight, 0)
  })
  @client.with_session(
    config=@client.SessionConfig::new(
      connection~,
      discovery=@client.DiscoveryConfig::new(address_mapper=_ => {
        Some(@client.Endpoint::new(port~))
      }),
    ),
    session => {
      @async.with_timeout(10000, () => {
        while session.control_status() is None ||
              session.control_status().unwrap().stale {
          @async.sleep(10)
        }
      })
      assert_true(
        session.query(
          "SELECT value FROM mooncql_permissions.business WHERE id=42",
        )
        is Rows(_),
      )
      ignore(session.drain(@client.Deadline::after(5000)))
      assert_eq(session.resources().background_task_handles, 0)
    },
  )
  println(
    "PASS minimum business SELECT/MODIFY, denied protected table and DDL, public system metadata, TLS discovery and drained resources",
  )
}
