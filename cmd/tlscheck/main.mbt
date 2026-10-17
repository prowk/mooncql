///|
async fn main {
  let identity = match @env.get_env_var("CQL_TLS_CLIENT_THUMBPRINT") {
    Some(thumbprint) => Some(@client.ClientIdentity::WindowsStore(thumbprint))
    None =>
      match @env.get_env_var("CQL_TLS_CLIENT_CERT") {
        Some(certificate) => {
          guard @env.get_env_var("CQL_TLS_CLIENT_KEY") is Some(key) else {
            fail("missing client key")
          }
          Some(@client.ClientIdentity::Pem(certificate, key))
        }
        None => None
      }
  }
  let config = @client.Config::new(
    port=@string.parse_int(@env.get_env_var("CQL_PORT").unwrap_or("19044")),
    username?=@env.get_env_var("CQL_USERNAME"),
    password?=@env.get_env_var("CQL_PASSWORD"),
    compression=@env.get_env_var("CQL_COMPRESSION") == Some("lz4"),
    tls=@client.TlsConfig::new(
      server_name?=@env.get_env_var("CQL_TLS_NAME"),
      ca_file?=@env.get_env_var("CQL_TLS_CA"),
      identity?,
    ),
  )
  let expected_failure = @env.get_env_var("CQL_TLS_EXPECT_FAIL") == Some("1")
  let connected = try {
    @client.with_connection(config~, connection => {
      if @env.get_env_var("CQL_TLS_CANCEL") == Some("1") {
        @async.with_task_group(requests => {
          let task = requests.spawn(() => {
            connection.query("SELECT release_version FROM system.local")
          })
          @async.sleep(50)
          task.cancel()
          ignore(task.wait()) catch {
            _ => ()
          }
        })
        assert_true(!connection.is_closed())
        assert_eq(connection.abandoned_count(), 1)
      }
      guard connection.query("SELECT release_version FROM system.local")
        is Rows(page) else {
        fail("missing version")
      }
      assert_true(page.get(0, "release_version") is Text(_))
      if @env.get_env_var("CQL_TLS_LARGE") == Some("1") {
        let payload = Bytes::make(400000, b'x')
        guard connection.query(
            "SELECT blobAsVarchar(?) AS value FROM system.local",
            values=[Bytes(payload)],
          )
          is Rows(page) else {
          fail("missing large value")
        }
        guard page.get(0, "value") is Text(value) else { fail("missing text") }
        assert_eq(@utf8.encode(value), payload)
      }
      while connection.abandoned_count() > 0 {
        @async.sleep(1)
      }
      assert_eq(connection.in_flight_bytes(), 0L)
    })
    true
  } catch {
    @client.TlsFailure(message) => {
      if !expected_failure {
        println(message)
      }
      false
    }
    @os_error.OSError(_, ..) if expected_failure => false
    @client.Closed if expected_failure => false
    error => raise error
  }
  assert_eq(connected, !expected_failure)
  println(
    if expected_failure {
      "PASS TLS rejected invalid peer or client credentials"
    } else {
      "PASS verified TLS query"
    },
  )
}
