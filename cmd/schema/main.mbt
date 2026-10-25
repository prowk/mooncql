///|
async fn main {
  let names = @env.get_env_var("CQL_SCHEMA_KEYSPACES")
    .map(value => value.split(",").map(name => name.to_owned()).to_array())
    .unwrap_or([])
  let config = @client.ConnectionBuilder::new(
    host=@env.get_env_var("CQL_HOST").unwrap_or("127.0.0.1"),
    port=@string.parse_int(@env.get_env_var("CQL_PORT").unwrap_or("9042")),
    username?=@env.get_env_var("CQL_USERNAME"),
    password?=@env.get_env_var("CQL_PASSWORD"),
    compression=@env.get_env_var("CQL_COMPRESSION") == Some("lz4"),
  )
  @client.with_session_builder(
    config=@client.SessionBuilder::new(connection=config),
    session => {
      let snapshot = session.schema_metadata(
        options=@client.SchemaOptions::new(keyspaces=names),
      )
      let report = "{\"schema_version\":\"\{@hex.encode(snapshot.schema_version())}\",\"keyspaces\":\{snapshot.keyspaces().to_json().stringify()},\"tables\":\{snapshot.tables().to_json().stringify()},\"user_types\":\{snapshot.user_types().to_json().stringify()}}"
      if @env.get_env_var("CQL_SCHEMA_REPORT") is Some(path) {
        @fs.write_file(path, report + "\n")
      } else {
        println(report)
      }
      assert_eq(
        session.drain(@client.Deadline::after(2000)),
        @client.DrainOutcome::Drained,
      )
      assert_eq(session.resources().background_task_handles, 0)
      println("PASS complete schema snapshot")
    },
  )
}
