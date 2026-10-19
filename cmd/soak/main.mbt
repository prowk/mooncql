///|
extern "C" fn rss_bytes() -> Int64 = "prowk_mooncql_soak_rss"

///|
extern "C" fn private_bytes() -> Int64 = "prowk_mooncql_soak_private"

///|
struct Counters {
  mut successful : Int64
  mut failed : Int64
  operations : Map[String, Int64]
  errors : Map[String, Int64]
  latency : Array[Int64]
  mut max_latency_ms : Int64
  mut cache_peak : Int
  mut stopping : Bool
}

///|
let latency_bounds : Array[Int64] = [
  1L, 2L, 5L, 10L, 20L, 50L, 100L, 200L, 500L, 1000L, 2000L, 5000L, 10000L, 2147483647L,
]

///|
fn transient_reason(error : Error) -> String? {
  match error {
    @client.ExecutionError(cause, _) => transient_reason(cause)
    @client.RetryExhausted(failures) => {
      guard failures.last() is Some(last) else { return None }
      transient_reason(last.error)
    }
    @client.Closed | @io.ReaderClosed | @os_error.OSError(_, ..) =>
      Some("disconnected")
    @client.AbandonedLimitExceeded => Some("abandoned_limit")
    @client.AbandonedRequestExpired => Some("abandoned_expired")
    @client.TimedOut(info) =>
      Some("timeout:\{info.phase.to_repr()}:sent=\{info.may_have_been_sent}")
    @client.Overloaded(_) => Some("local_overload")
    @client.Server(server) =>
      match server.code {
        0x1000 | 0x1001 | 0x1002 | 0x1100 | 0x1200 | 0x1300 | 0x1500 | 0x1700 =>
          Some("server:\{server.code}")
        _ => None
      }
    _ => None
  }
}

///|
async fn observed(
  counters : Counters,
  mode : String,
  action : async () -> Unit,
) -> Unit {
  let start = @async.now()
  let outcome = try {
    action()
    Ok(())
  } catch {
    error => Err(error)
  }
  let elapsed = @async.now() - start
  for index, bound in latency_bounds {
    if elapsed <= bound {
      counters.latency[index] += 1L
      break
    }
  }
  if elapsed > counters.max_latency_ms {
    counters.max_latency_ms = elapsed
  }
  match outcome {
    Ok(_) => {
      counters.successful += 1L
      counters.operations[mode] = counters.operations.get(mode).unwrap() + 1L
    }
    Err(error) => {
      guard transient_reason(error) is Some(reason) else { raise error }
      counters.failed += 1L
      counters.errors[reason] = counters.errors.get(reason).unwrap_or(0L) + 1L
    }
  }
}

///|
fn values(
  device : Int,
  id : Int,
  small : Bytes,
  large : Bytes,
) -> Array[@types.Value] {
  [
    Integer(device),
    Integer(id),
    BigInteger(9007199254740993L + (device * 1000 + id).to_int64()),
    Text("事件 \{device}/\{id}"),
    Bytes(if id % 16 == 0 { large } else { small }),
  ]
}

///|
fn check_row(
  page : @protocol.Page,
  index : Int,
  device : Int,
  id : Int,
  small : Bytes,
  large : Bytes,
) -> Unit raise {
  let row = page.row(index)
  assert_eq(row.int("id"), id)
  assert_eq(
    row.int64("large_value"),
    9007199254740993L + (device * 1000 + id).to_int64(),
  )
  assert_eq(row.text("message"), "事件 \{device}/\{id}")
  assert_eq(row.bytes("payload"), if id % 16 == 0 { large } else { small })
}

///|
async fn wait_ready(session : @client.Session) -> Unit {
  @async.with_timeout(180000, () => {
    while session.nodes().filter(node => node.status.state == Ready).length() !=
          3 ||
          !(session.control_status() is Some({ connected: true, .. })) {
      @async.sleep(25)
    }
  })
}

///|
async fn schema_agreement(session : @client.Session) -> Unit {
  @async.with_timeout(60000, () => {
    while true {
      let versions = []
      for _ in 0..<3 {
        guard session.query("SELECT schema_version FROM system.local")
          is Rows(page) else {
          fail("missing schema version")
        }
        versions.push(page.row(0).uuid("schema_version").to_bytes())
      }
      if versions[0] == versions[1] && versions[1] == versions[2] {
        return
      }
      @async.sleep(100)
    }
  })
}

///|
async fn sample(
  directory : String,
  session : @client.Session,
  metrics : @client.Metrics,
  counters : Counters,
  elapsed : Int64,
) -> Unit {
  let resources = session.resources()
  for count in resources.cache_sizes {
    assert_true(count <= 16)
    if count > counters.cache_peak {
      counters.cache_peak = count
    }
  }
  let memory = rss_bytes()
  let private_memory = private_bytes()
  assert_true(memory > 0L && private_memory > 0L)
  let control_generation = session
    .control_status()
    .map(status => status.generation)
    .unwrap_or(0)
  let json = "{\"elapsed_ms\":\{elapsed},\"successful\":\{counters.successful},\"failed\":\{counters.failed},\"operations\":\{counters.operations.to_json().stringify()},\"errors\":\{counters.errors.to_json().stringify()},\"memory_bytes\":\{memory},\"private_bytes\":\{private_memory},\"cache_peak\":\{counters.cache_peak},\"control_generation\":\{control_generation},\"resources\":\{resources.to_json().stringify()},\"metrics\":\{metrics.snapshot().to_json().stringify()},\"latency_bounds_ms\":\{latency_bounds.to_json().stringify()},\"latency_counts\":\{counters.latency.to_json().stringify()},\"max_latency_ms\":\{counters.max_latency_ms}}"
  @fs.write_file("\{directory}/progress.json", json)
  @fs.write_file("\{directory}/samples.jsonl", json + "\n", append=true)
}

///|
async fn run() -> Unit {
  let directory = @env.get_env_var("CQL_SOAK_DIR").unwrap()
  let duration = @string.parse_int(
    @env.get_env_var("CQL_SOAK_SECONDS").unwrap_or("21600"),
  )
  if duration < 120 || duration > 172800 {
    fail("duration must be 120..172800 seconds")
  }
  let ports = []
  for
    port in @env.get_env_var("CQL_CLUSTER_PORTS")
    .unwrap_or("19052,19053,19054")
    .split(",") {
    ports.push(@string.parse_int(port))
  }
  let hosts = @env.get_env_var("CQL_CLUSTER_NATIVE_HOSTS")
    .unwrap()
    .split(",")
    .map(host => host.to_owned())
    .to_array()
  assert_eq(ports.length(), 3)
  assert_eq(hosts.length(), 3)
  let metrics = @client.Metrics::new()
  let config = @client.SessionConfig::new(
    connection=@client.Config::new(
      username?=@env.get_env_var("CQL_USERNAME"),
      password?=@env.get_env_var("CQL_PASSWORD"),
      compression=@env.get_env_var("CQL_COMPRESSION") == Some("lz4"),
      operation_timeout_ms=10000,
      connect_timeout_ms=3000,
      prepared_cache_capacity=16,
      max_in_flight=32,
      max_waiting=64,
      metrics~,
    ),
    contact_points=[@client.Endpoint::new(port=ports[0])],
    discovery=@client.DiscoveryConfig::new(
      refresh_interval_ms=5000,
      max_nodes=3,
      address_mapper=native => {
        if native.address.length() != 4 {
          return None
        }
        let ip = "\{native.address[0].to_int()}.\{native.address[1].to_int()}.\{native.address[2].to_int()}.\{native.address[3].to_int()}"
        for index in 0..<3 {
          if ip == hosts[index] &&
            (native.port == 9042 || native.port == ports[index]) {
            return Some(@client.Endpoint::new(port=ports[index]))
          }
        }
        None
      },
    ),
    routing=@client.RoutingConfig::new("dc1"),
  )
  let counters = Counters::{
    successful: 0L,
    failed: 0L,
    operations: Map([]),
    errors: Map([]),
    latency: Array::make(latency_bounds.length(), 0L),
    max_latency_ms: 0L,
    cache_peak: 0,
    stopping: false,
  }
  let modes = [
    "write", "write", "read", "read", "page", "lwt", "cache", "batch", "schema",
  ]
  for mode in modes {
    counters.operations[mode] = 0L
  }
  let small = b"mooncql steady state event payload"
  let mut random = 2026101820U
  let large = Bytes::from_array(
    Array::makei(400000, _ => {
      random = random ^ (random << 13)
      random = random ^ (random >> 17)
      random = random ^ (random << 5)
      (random >> 24).reinterpret_as_int().to_byte()
    }),
  )
  let report = @client.with_session(config~, session => {
    wait_ready(session)
    guard session.query("SELECT release_version FROM system.local")
      is Rows(server) else {
      fail("missing version")
    }
    assert_eq(server.row(0).text("release_version"), "5.0.5")
    if @env.get_env_var("CQL_USERNAME") is Some(_) {
      ignore(
        session.query(
          "ALTER KEYSPACE system_auth WITH replication = {'class':'NetworkTopologyStrategy','dc1':3}",
        ),
      )
      schema_agreement(session)
    }
    ignore(
      session.query(
        "CREATE KEYSPACE IF NOT EXISTS mooncql_soak WITH replication = {'class':'NetworkTopologyStrategy','dc1':3}",
      ),
    )
    schema_agreement(session)
    ignore(
      session.query(
        "CREATE TABLE IF NOT EXISTS mooncql_soak.events (device int, id int, large_value bigint, message text, payload blob, PRIMARY KEY (device,id))",
      ),
    )
    ignore(
      session.query(
        "CREATE TABLE IF NOT EXISTS mooncql_soak.cas_probe (id int PRIMARY KEY, version bigint)",
      ),
    )
    schema_agreement(session)
    let insert_cql = "INSERT INTO mooncql_soak.events (device,id,large_value,message,payload) VALUES (?,?,?,?,?)"
    let insert = session.prepare(insert_cql)
    let read = session.prepare(
      "SELECT id,large_value,message,payload FROM mooncql_soak.events WHERE device=? AND id=?",
    )
    let scan = session.prepare(
      "SELECT id,large_value,message,payload FROM mooncql_soak.events WHERE device=?",
    )
    let cas_read = session.prepare(
      "SELECT version FROM mooncql_soak.cas_probe WHERE id=1",
    )
    let cas_write = session.prepare(
      "UPDATE mooncql_soak.cas_probe SET version=? WHERE id=1 IF version=?",
    )
    let options = @protocol.QueryOptions::new(
      consistency=Quorum,
      skip_metadata=true,
    )
    for device in 0..<4 {
      for id in 0..<64 {
        ignore(
          insert.execute(
            values(device, id, small, large),
            options=@protocol.QueryOptions::new(consistency=All),
          ),
        )
      }
    }
    ignore(
      session.query(
        "INSERT INTO mooncql_soak.cas_probe (id,version) VALUES (1,9007199254740993)",
        options=@protocol.QueryOptions::new(consistency=All),
      ),
    )
    let start = @async.now()
    @fs.write_file(
      "\{directory}/ready.json",
      "{\"duration_seconds\":\{duration},\"capacity\":16}",
    )
    let load_elapsed = @async.with_task_group(group => {
      let sampler = group.spawn(() => {
        while !counters.stopping {
          sample(directory, session, metrics, counters, @async.now() - start)
          @async.sleep(10000)
        }
      })
      let workers = []
      for worker, mode in modes {
        workers.push(
          group.spawn(() => {
            let mut sequence = 0
            while @async.now() - start < duration.to_int64() * 1000L {
              let id = sequence % 64
              observed(counters, mode, () => {
                match mode {
                  "write" =>
                    assert_true(
                      insert.execute(values(worker, id, small, large), options~)
                      is Void,
                    )
                  "read" => {
                    let device = worker - 2
                    let tracing = sequence % 1024 == 0
                    let request_options = @protocol.RequestOptions::new(
                      tracing~,
                      custom_payload=Map([("sample", Some(b"soak"))]),
                    )
                    let execution = read.execute_with_info(
                      [Integer(device), Integer(id)],
                      options={
                        ..options,
                        request_options: Some(request_options),
                      },
                      idempotent=true,
                    )
                    guard execution.value is Rows(page) else {
                      fail("missing row")
                    }
                    assert_eq(page.rows.length(), 1)
                    check_row(page, 0, device, id, small, large)
                    if tracing {
                      assert_true(execution.info.tracing_id is Some(_))
                    }
                  }
                  "page" => {
                    let paging_options = @protocol.QueryOptions::new(
                      consistency=Quorum,
                      page_size=7,
                      skip_metadata=true,
                    )
                    let mut pager = scan.pages(
                      [Integer(0)],
                      options=paging_options,
                    )
                    let mut expected = 0
                    while pager.next() is Some(page) {
                      for index in 0..<page.rows.length() {
                        check_row(page, index, 0, expected, small, large)
                        expected += 1
                      }
                      if expected == 7 {
                        let cursor = @client.PagingCursor::from_bytes(
                          pager.cursor().to_bytes(),
                        )
                        pager = scan.pages(
                          [Integer(0)],
                          options=paging_options,
                          cursor~,
                        )
                      }
                    }
                    assert_eq(expected, 64)
                  }
                  "lwt" => {
                    guard cas_read.execute([], options~) is Rows(page) else {
                      fail("missing CAS version")
                    }
                    let version = page.row(0).int64("version")
                    let result = cas_write.execute_conditional(
                      [BigInteger(version + 1L), BigInteger(version)],
                      options=@protocol.QueryOptions::new(
                        consistency=Quorum,
                        serial_consistency=LocalSerial,
                        skip_metadata=true,
                      ),
                    )
                    assert_eq(result.page.rows.length(), 1)
                    assert_eq(
                      result.page.row(0).boolean("[applied]"),
                      result.applied,
                    )
                  }
                  "cache" => {
                    let statement = session.prepare(
                      "SELECT id,large_value,message,payload FROM mooncql_soak.events WHERE device=? AND id=? /* cache \{sequence % 128} */",
                    )
                    guard statement.execute([Integer(0), Integer(id)], options~)
                      is Rows(page) else {
                      fail("missing churn row")
                    }
                    check_row(page, 0, 0, id, small, large)
                  }
                  "batch" => {
                    let request = @protocol.batch(
                      [
                        Query(insert_cql, values(3, id, small, large)),
                        Query(
                          insert_cql,
                          values(3, (id + 1) % 64, small, large),
                        ),
                      ],
                      kind=Unlogged,
                      options=@protocol.QueryOptions::new(consistency=Quorum),
                    )
                    match session.request(request).response {
                      Result(Void) => ()
                      Failure(server) => raise @client.Server(server)
                      _ => fail("invalid BATCH response")
                    }
                  }
                  _ => {
                    let cql = if sequence % 2 == 0 {
                      "CREATE TABLE IF NOT EXISTS mooncql_soak.schema_probe (id int PRIMARY KEY)"
                    } else {
                      "DROP TABLE IF EXISTS mooncql_soak.schema_probe"
                    }
                    ignore(session.query(cql))
                  }
                }
              })
              sequence += 1
              let pause = match mode {
                "page" => 100
                "lwt" | "cache" => 30
                "schema" => 30000
                _ => 10
              }
              let remaining = duration.to_int64() * 1000L -
                (@async.now() - start)
              if remaining > 0L {
                @async.sleep(
                  if remaining < pause.to_int64() {
                    remaining.to_int()
                  } else {
                    pause
                  },
                )
              }
            }
          }),
        )
      }
      for worker in workers {
        worker.wait()
      }
      let elapsed = @async.now() - start
      counters.stopping = true
      sampler.wait()
      elapsed
    })
    sample(directory, session, metrics, counters, load_elapsed)
    wait_ready(session)
    @async.with_timeout(30000, () => {
      while session.resources().pending > 0 ||
            session.resources().in_flight > 0 ||
            session.resources().waiting > 0 {
        @async.sleep(1)
      }
    })
    let quiet = session.resources()
    assert_eq(quiet.active, 0)
    assert_eq(quiet.pending, 0)
    assert_eq(quiet.abandoned, 0)
    assert_eq(quiet.in_flight_bytes, 0L)
    assert_eq(quiet.waiting_bytes, 0L)
    session.close()
    let closed = session.resources()
    assert_eq(closed.background_task_handles, 0)
    assert_eq(closed.pending, 0)
    assert_eq(closed.active, 0)
    assert_eq(closed.waiting, 0)
    let final_metrics = metrics.snapshot()
    assert_eq(final_metrics.in_flight, 0L)
    assert_eq(final_metrics.waiting, 0L)
    assert_eq(final_metrics.in_flight_bytes, 0L)
    assert_eq(final_metrics.waiting_bytes, 0L)
    assert_eq(
      final_metrics.connections_established,
      final_metrics.connections_closed,
    )
    "{\"load_elapsed_ms\":\{load_elapsed},\"background_joined\":true,\"active\":0,\"waiting\":0,\"pending\":0,\"cache_peak\":\{counters.cache_peak},\"cache_capacity\":16,\"successful\":\{counters.successful},\"failed\":\{counters.failed},\"operations\":\{counters.operations.to_json().stringify()},\"errors\":\{counters.errors.to_json().stringify()},\"quiet_resources\":\{quiet.to_json().stringify()},\"closed_resources\":\{closed.to_json().stringify()},\"final_metrics\":\{final_metrics.to_json().stringify()}}"
  })
  // 外层 Session 任务组已经退出后才发布最终报告，确保作用域任务都已等待结束。
  @fs.write_file("\{directory}/result.json", report + "\n")
}

///|
async fn main {
  run() catch {
    @client.Server(server) => fail("server \{server.code}: \{server.message}")
    @client.Configuration(message) | @client.Unexpected(message) =>
      fail(message)
    error => raise error
  }
}
