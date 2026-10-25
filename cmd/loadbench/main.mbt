///|
extern "C" fn now_ns() -> Int64 = "prowk_mooncql_bench_now_ns"

///|
extern "C" fn cpu_ns() -> Int64 = "prowk_mooncql_bench_cpu_ns"

///|
extern "C" fn peak_bytes() -> Int64 = "prowk_mooncql_bench_peak_bytes"

///|
fn number(name : String, fallback : String) -> Int raise {
  @string.parse_int(@env.get_env_var(name).unwrap_or(fallback))
}

///|
fn rank(sorted : Array[Int64], percent : Int) -> Int64 {
  if sorted.is_empty() {
    0L
  } else {
    sorted[(sorted.length() * percent + 99) / 100 - 1]
  }
}

///|
async fn main {
  let count = number("LOAD_COUNT", "1000")
  let concurrency = number("LOAD_CONCURRENCY", "32")
  let rate = number("LOAD_RATE", "0")
  let size = number("LOAD_SIZE", "64")
  let partitions = number("LOAD_PARTITIONS", "32")
  let distribution = @env.get_env_var("LOAD_DISTRIBUTION").unwrap_or("uniform")
  let observe = @env.get_env_var("LOAD_OBSERVE").unwrap_or("on") == "on"
  if count < 1 ||
    count > 200000 ||
    concurrency < 1 ||
    concurrency > 128 ||
    rate < 0 ||
    rate > 1000000 ||
    partitions < 1 ||
    partitions > 1024 ||
    (size != 64 && size != 400000) ||
    (distribution != "hot" && distribution != "uniform") {
    fail("invalid LOAD_* configuration")
  }
  let rpc = []
  let recording = [false]
  let metrics = make_metrics(observe, recording, rpc)
  let data = Bytes::make(size, b'x')
  let config = @client.ConnectionBuilder::new(
    host=@env.get_env_var("CQL_HOST").unwrap_or("127.0.0.1"),
    port=number("CQL_PORT", "9042"),
    username?=@env.get_env_var("CQL_USERNAME"),
    password?=@env.get_env_var("CQL_PASSWORD"),
    compression=@env.get_env_var("CQL_COMPRESSION") == Some("lz4"),
    max_in_flight=32,
    max_waiting=128,
    timeout_ms=10000,
    metrics?,
  )
  @client.with_connection_builder(config~, connection => {
    ignore(
      connection.query(
        "CREATE KEYSPACE IF NOT EXISTS mooncql_loadbench WITH replication = {'class':'SimpleStrategy','replication_factor':1}",
      ),
    )
    ignore(
      connection.query(
        "CREATE TABLE IF NOT EXISTS mooncql_loadbench.probe (partition int PRIMARY KEY, data blob)",
      ),
    )
    let insert = connection.prepare(
      "INSERT INTO mooncql_loadbench.probe (partition,data) VALUES (?,?)",
    )
    for partition in 0..<partitions {
      ignore(insert.execute([Integer(partition), Bytes(data)]))
    }
    let select = connection.prepare(
      "SELECT data FROM mooncql_loadbench.probe WHERE partition=?",
    )
    for _ in 0..<8 {
      ignore(select.execute([Integer(0)]))
    }
    // 计时器调用与采样数组写入的空载成本单独保留，不从业务延迟中武断扣减。
    let overhead_cpu = cpu_ns()
    let overhead_start = now_ns()
    let empty = Array::make(count, 0L)
    for index in 0..<count {
      empty[index] = now_ns()
    }
    let overhead_ns = now_ns() - overhead_start
    let overhead_cpu_ns = cpu_ns() - overhead_cpu
    let raw = []
    let latencies = []
    let mut next = 0
    let mut successes = 0
    let mut failures = 0
    let mut timeouts = 0
    let mut rejections = 0
    let started_ms = @async.now()
    let started = now_ns()
    let started_cpu = cpu_ns()
    recording[0] = true
    async fn worker() -> Unit {
      let mut ready_at = 0L
      while next < count {
        let id = next
        next += 1
        let planned = if rate == 0 {
          ready_at
        } else {
          id.to_int64() * 1000000000L / rate.to_int64()
        }
        let remaining = planned - (now_ns() - started)
        if remaining > 0L {
          @async.sleep(((remaining + 999999L) / 1000000L).to_int())
        }
        let dispatched = now_ns() - started
        // 开环计划独立于完成时间；过期到达仍被计入队列延迟，不能静默丢弃。
        let partition = if distribution == "hot" { 0 } else { id % partitions }
        let outcome = try {
          guard select.execute([Integer(partition)]) is Rows(page) else {
            fail("missing result")
          }
          assert_eq(page.row(0).bytes("data"), data)
          successes += 1
          "success"
        } catch {
          @client.TimedOut(_) => {
            timeouts += 1
            "timeout"
          }
          @client.Overloaded(_) => {
            rejections += 1
            "rejected"
          }
          _ => {
            failures += 1
            "failed"
          }
        }
        let completed = now_ns() - started
        latencies.push(completed - planned)
        raw.push(
          "{\"type\":\"operation\",\"id\":\{id},\"partition\":\{partition},\"planned_ns\":\{planned},\"enqueued_ns\":\{planned},\"dispatched_ns\":\{dispatched},\"completed_ns\":\{completed},\"outcome\":\"\{outcome}\"}",
        )
        ready_at = completed
      }
    }
    ignore(
      @async.all(
        Array::makei(concurrency, _ => worker),
        max_concurrent=concurrency,
      ),
    )
    recording[0] = false
    let elapsed = now_ns() - started
    let cpu = cpu_ns() - started_cpu
    assert_eq(successes + failures + timeouts + rejections, count)
    assert_eq(connection.pending_count(), 0)
    assert_eq(connection.waiting_count(), 0)
    latencies.sort()
    for sample in raw {
      println(sample)
    }
    for sample in rpc {
      println(sample)
    }
    println(
      "{\"type\":\"summary\",\"count\":\{count},\"successes\":\{successes},\"failures\":\{failures},\"timeouts\":\{timeouts},\"rejections\":\{rejections},\"elapsed_ns\":\{elapsed},\"cpu_ns\":\{cpu},\"peak_memory_bytes\":\{peak_bytes()},\"p50_ns\":\{rank(latencies, 50)},\"p95_ns\":\{rank(latencies, 95)},\"p99_ns\":\{rank(latencies, 99)},\"sampling_overhead_ns\":\{overhead_ns},\"sampling_cpu_ns\":\{overhead_cpu_ns},\"origin_ms\":\{started_ms},\"rpc_samples\":\{rpc.length()}}",
    )
  })
}
