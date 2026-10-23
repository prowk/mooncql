///|
extern "C" fn now_ns() -> Int64 = "prowk_mooncql_bench_now_ns"

///|
extern "C" fn cpu_ns() -> Int64 = "prowk_mooncql_bench_cpu_ns"

///|
extern "C" fn peak_bytes() -> Int64 = "prowk_mooncql_bench_peak_bytes"

///|
fn integer_env(name : String, fallback : String) -> Int raise {
  @string.parse_int(@env.get_env_var(name).unwrap_or(fallback))
}

///|
fn percentile(values : Array[Int64], percent : Int) -> Int64 {
  if values.is_empty() {
    0L
  } else {
    values[(values.length() * percent + 99) / 100 - 1]
  }
}

///|
fn payload(size : Int, entropy : String) -> Bytes {
  let mut random = 2026101821U
  Bytes::from_array(
    Array::makei(size, index => {
      if entropy == "repeat" {
        (index % 4 + 65).to_byte()
      } else {
        random = random ^ (random << 13)
        random = random ^ (random >> 17)
        random = random ^ (random << 5)
        (random >> 24).reinterpret_as_int().to_byte()
      }
    }),
  )
}

///|
async fn main {
  let mode = @env.get_env_var("BENCH_MODE").unwrap_or("read")
  let entropy = @env.get_env_var("BENCH_ENTROPY").unwrap_or("repeat")
  let size = integer_env("BENCH_SIZE", "64")
  let count = integer_env("BENCH_COUNT", "1000")
  let concurrency = integer_env("BENCH_CONCURRENCY", "32")
  let page_size = integer_env("BENCH_PAGE_SIZE", "4")
  let connections = integer_env("BENCH_CONNECTIONS", "1")
  let compressed = @env.get_env_var("CQL_COMPRESSION") == Some("lz4")
  if (mode != "read" && mode != "write" && mode != "page") ||
    (entropy != "repeat" && entropy != "random") ||
    (size != 64 && size != 400000) ||
    count < 1 ||
    count > 1000000 ||
    concurrency < 1 ||
    concurrency > 128 ||
    page_size < 1 ||
    page_size > 16 ||
    connections < 1 ||
    connections > 8 {
    fail("invalid Session pool benchmark configuration")
  }
  let data = payload(size, entropy)
  @client.with_session(
    config=@client.SessionConfig::new(
      connection=@client.Config::new(
        host=@env.get_env_var("CQL_HOST").unwrap_or("127.0.0.1"),
        port=integer_env("CQL_PORT", "9042"),
        username?=@env.get_env_var("CQL_USERNAME"),
        password?=@env.get_env_var("CQL_PASSWORD"),
        compression=compressed,
        max_in_flight=128,
        max_waiting=128,
        timeout_ms=60000,
        heartbeat_interval_ms=0,
      ),
      connections_per_node=connections,
      limits=@client.SessionLimits::new(max_in_flight=128, max_waiting=128),
    ),
    session => {
      @async.with_timeout(30000, () => {
        while session.pools()[0].ready != connections {
          @async.sleep(1)
        }
      })
      guard session.query("SELECT release_version FROM system.local")
        is Rows(version) else {
        fail("missing server version")
      }
      let version = version.row(0).text("release_version")
      ignore(
        session.query(
          "CREATE KEYSPACE IF NOT EXISTS mooncql_bench WITH replication = {'class':'SimpleStrategy','replication_factor':1}",
        ),
      )
      ignore(
        session.query(
          "CREATE TABLE IF NOT EXISTS mooncql_bench.probe (partition text,id int,data blob,PRIMARY KEY(partition,id))",
        ),
      )
      let partition = "\{size}_\{entropy}"
      let insert = session.prepare(
        "INSERT INTO mooncql_bench.probe (partition,id,data) VALUES (?,?,?)",
      )
      for id in 0..<9 {
        ignore(insert.execute([Text(partition), Integer(id), Bytes(data)]))
      }
      let select = session.prepare(
        "SELECT id,data FROM mooncql_bench.probe WHERE partition=? AND id=0",
      )
      let scan = session.prepare(
        "SELECT id,data FROM mooncql_bench.probe WHERE partition=?",
      )
      let samples = []
      let pages = []
      async fn operation(record : Bool) -> Unit {
        let started = now_ns()
        match mode {
          "write" =>
            assert_true(
              insert.execute([Text(partition), Integer(0), Bytes(data)]) is Void,
            )
          "read" => {
            guard select.execute([Text(partition)]) is Rows(page) else {
              fail("missing read row")
            }
            assert_eq(page.rows.length(), 1)
            assert_eq(page.row(0).int("id"), 0)
            assert_eq(page.row(0).bytes("data"), data)
          }
          _ => {
            let pager = scan.pages(
              [Text(partition)],
              options=@protocol.QueryOptions::new(
                page_size~,
                skip_metadata=true,
              ),
            )
            let mut id = 0
            while true {
              let before = now_ns()
              guard pager.next() is Some(page) else { break }
              if record {
                pages.push(now_ns() - before)
              }
              for index in 0..<page.rows.length() {
                assert_eq(page.row(index).int("id"), id)
                assert_eq(page.row(index).bytes("data"), data)
                id += 1
              }
            }
            assert_eq(id, 9)
          }
        }
        if record {
          samples.push(now_ns() - started)
        }
      }
      for _ in 0..<8 {
        operation(false)
      }
      let cpu = cpu_ns()
      let start = now_ns()
      ignore(
        @async.all(
          Array::makei(count, _ => () => operation(true)),
          max_concurrent=concurrency,
        ),
      )
      let elapsed = now_ns() - start
      let measured_cpu = cpu_ns() - cpu
      assert_eq(samples.length(), count)
      assert_eq(session.resources().pending, 0)
      assert_eq(session.resources().abandoned, 0)
      assert_eq(session.resources().waiting, 0)
      guard select.execute([Text(partition)]) is Rows(final_page) else {
        fail("missing final row")
      }
      assert_eq(final_page.row(0).bytes("data"), data)
      let tasks = session.resources().background_task_handles
      assert_eq(session.pools()[0].ready, connections)
      assert_eq(
        session.drain(@client.Deadline::after(5000)),
        @client.DrainOutcome::Drained,
      )
      assert_eq(session.resources().background_task_handles, 0)
      assert_eq(session.resources().pending, 0)
      assert_eq(session.budget().in_flight, 0)
      assert_eq(session.budget().in_flight_bytes, 0L)
      assert_eq(session.budget().waiting_bytes, 0L)
      assert_eq(session.budget().waiting, 0)
      samples.sort()
      pages.sort()
      let rate = count.to_double() * 1000000000.0 / elapsed.to_double()
      let cpu_percent = measured_cpu.to_double() * 100.0 / elapsed.to_double()
      let actual_page_size = if mode == "page" { page_size } else { 0 }
      println(
        "{\"uses_session_pool\":true,\"resources_drained\":true,\"background_task_handles\":\{tasks},\"physical_connections\":\{connections},\"connections\":\{connections},\"mode\":\"\{mode}\",\"entropy\":\"\{entropy}\",\"size\":\{size},\"compressed\":\{compressed},\"count\":\{count},\"concurrency\":\{concurrency},\"page_size\":\{actual_page_size},\"elapsed_ns\":\{elapsed},\"cpu_ns\":\{measured_cpu},\"cpu_percent\":\{cpu_percent},\"peak_memory_bytes\":\{peak_bytes()},\"operations_per_second\":\{rate},\"p50_ns\":\{percentile(samples,50)},\"p95_ns\":\{percentile(samples,95)},\"p99_ns\":\{percentile(samples,99)},\"page_count\":\{pages.length()},\"page_p50_ns\":\{percentile(pages,50)},\"page_p95_ns\":\{percentile(pages,95)},\"page_p99_ns\":\{percentile(pages,99)},\"server_version\":\"\{version}\"}",
      )
    },
  )
}
