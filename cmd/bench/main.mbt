///|
extern "C" fn now_ns() -> Int64 = "prowk_mooncql_bench_now_ns"

///|
extern "C" fn cpu_ns() -> Int64 = "prowk_mooncql_bench_cpu_ns"

///|
extern "C" fn peak_bytes() -> Int64 = "prowk_mooncql_bench_peak_bytes"

///|
fn integer_env(name : String, fallback : String) -> Int32 raise {
  @string.parse_int(@env.get_env_var(name).unwrap_or(fallback))
}

///|
fn percentile(sorted : Array[Int64], percent : Int32) -> Int64 {
  if sorted.is_empty() {
    0L
  } else {
    sorted[(sorted.length() * percent + 99) / 100 - 1]
  }
}

///|
fn payload(size : Int32, entropy : String) -> Bytes {
  let mut random = 2026101821U
  Bytes::from_array(
    Array::makei(size, index => {
      if entropy == "repeat" {
        (index % 4 + 65).to_byte()
      } else {
        // xorshift32 的高字节用于固定种子的不可压缩输入，避免低字节短周期。
        random = random ^ (random << 13)
        random = random ^ (random >> 17)
        random = random ^ (random << 5)
        (random >> 24).reinterpret_as_int().to_byte()
      }
    }),
  )
}

///|
fn print_result(
  mode : String,
  entropy : String,
  size : Int32,
  compressed : Bool,
  count : Int32,
  concurrency : Int32,
  page_size : Int32,
  elapsed : Int64,
  cpu : Int64,
  samples : Array[Int64],
  pages : Array[Int64],
  version : String,
  connections : Int32,
) -> Unit {
  samples.sort()
  pages.sort()
  let ops = count.to_double() * 1000000000.0 / elapsed.to_double()
  let cpu_percent = cpu.to_double() * 100.0 / elapsed.to_double()
  println(
    "{\"mode\":\"\{mode}\",\"entropy\":\"\{entropy}\",\"size\":\{size},\"compressed\":\{compressed},\"count\":\{count},\"concurrency\":\{concurrency},\"connections\":\{connections},\"page_size\":\{page_size},\"elapsed_ns\":\{elapsed},\"cpu_ns\":\{cpu},\"cpu_percent\":\{cpu_percent},\"peak_memory_bytes\":\{peak_bytes()},\"operations_per_second\":\{ops},\"p50_ns\":\{percentile(samples, 50)},\"p95_ns\":\{percentile(samples, 95)},\"p99_ns\":\{percentile(samples, 99)},\"page_count\":\{pages.length()},\"page_p50_ns\":\{percentile(pages, 50)},\"page_p95_ns\":\{percentile(pages, 95)},\"page_p99_ns\":\{percentile(pages, 99)},\"server_version\":\"\{version}\"}",
  )
}

///|
fn codec_operation(data : Bytes, compressed : Bool) -> Unit raise {
  let request = @protocol.query(
    "INSERT INTO mooncql_bench.probe (partition,id,data) VALUES (?,0,?)",
    values=[Text("codec"), Bytes(data)],
  )
  let envelope = @protocol.encode_envelope(7, request.opcode, request.body)
  let decoder = @protocol.EnvelopeDecoder::new()
  let messages = []
  for frame in @framing.split(envelope, compressed~) {
    for message in decoder.feed(@framing.decode(frame, compressed~)) {
      messages.push(message)
    }
  }
  assert_eq(messages.length(), 1)
  assert_eq(messages[0].body, request.body)
  assert_eq(messages[0].header.stream, 7)
}

///|
fn lz4_operation(blocks : Array[Bytes]) -> Unit raise {
  for block in blocks {
    assert_eq(
      @framing.lz4_decompress(@framing.lz4_compress(block), block.length()),
      block,
    )
  }
}

///|
async fn benchmark() -> Unit {
  let mode = @env.get_env_var("BENCH_MODE").unwrap_or("codec")
  let entropy = @env.get_env_var("BENCH_ENTROPY").unwrap_or("repeat")
  let size = integer_env("BENCH_SIZE", "64")
  let count = integer_env("BENCH_COUNT", "1000")
  let concurrency = integer_env("BENCH_CONCURRENCY", "32")
  let page_size = integer_env("BENCH_PAGE_SIZE", "4")
  let connection_count = integer_env("BENCH_CONNECTIONS", "1")
  let compressed = mode == "lz4" ||
    @env.get_env_var("CQL_COMPRESSION") == Some("lz4")
  if (size != 64 && size != 400000) ||
    count < 1 ||
    count > 1000000 ||
    concurrency < 1 ||
    concurrency > 128 ||
    connection_count < 1 ||
    connection_count > 8 ||
    page_size < 1 ||
    page_size > 16 ||
    (entropy != "repeat" && entropy != "random") {
    fail("invalid benchmark configuration")
  }
  let data = payload(size, entropy)
  if mode == "codec" || mode == "lz4" {
    let blocks = []
    let mut offset = 0
    while offset < data.length() {
      let end = if data.length() - offset > 131071 {
        offset + 131071
      } else {
        data.length()
      }
      blocks.push(data[offset:end].to_owned())
      offset = end
    }
    fn operation() -> Unit raise {
      if mode == "codec" {
        codec_operation(data, compressed)
      } else {
        lz4_operation(blocks)
      }
    }
    for _ in 0..<8 {
      operation()
    }
    let samples = Array::make(count, 0L)
    let cpu = cpu_ns()
    let start = now_ns()
    for index in 0..<count {
      let before = now_ns()
      operation()
      samples[index] = now_ns() - before
    }
    let elapsed = now_ns() - start
    print_result(
      mode,
      entropy,
      size,
      compressed,
      count,
      1,
      0,
      elapsed,
      cpu_ns() - cpu,
      samples,
      [],
      "",
      0,
    )
    return
  }
  if mode != "read" && mode != "write" && mode != "page" {
    fail("invalid benchmark mode")
  }
  let config = @client.ConnectionBuilder::new(
    host=@env.get_env_var("CQL_HOST").unwrap_or("127.0.0.1"),
    port=integer_env("CQL_PORT", "9042"),
    username?=@env.get_env_var("CQL_USERNAME"),
    password?=@env.get_env_var("CQL_PASSWORD"),
    compression=compressed,
    max_in_flight=128,
    max_waiting=128,
    timeout_ms=60000,
  )
  with_bench_connections(config, connection_count, [], connections => {
    let connection = connections[0]
    guard connection.query("SELECT release_version FROM system.local")
      is Rows(version) else {
      fail("missing server version")
    }
    let version = version.row(0).text("release_version")
    ignore(
      connection.query(
        "CREATE KEYSPACE IF NOT EXISTS mooncql_bench WITH replication = {'class':'SimpleStrategy','replication_factor':1}",
      ),
    )
    ignore(
      connection.query(
        "CREATE TABLE IF NOT EXISTS mooncql_bench.probe (partition text, id int, data blob, PRIMARY KEY (partition,id))",
      ),
    )
    let partition = "\{size}_\{entropy}"
    // 每条连接单独准备和保存句柄，基准不跨物理连接复用预处理状态。
    let inserts = []
    let selects = []
    let scans = []
    for current in connections {
      inserts.push(
        current.prepare(
          "INSERT INTO mooncql_bench.probe (partition,id,data) VALUES (?,?,?)",
        ),
      )
      selects.push(
        current.prepare(
          "SELECT id,data FROM mooncql_bench.probe WHERE partition=? AND id=0",
        ),
      )
      scans.push(
        current.prepare(
          "SELECT id,data FROM mooncql_bench.probe WHERE partition=?",
        ),
      )
    }
    let insert = inserts[0]
    for id in 0..<9 {
      ignore(insert.execute([Text(partition), Integer(id), Bytes(data)]))
    }
    let mut next_connection = 0
    let samples = []
    let pages = []
    async fn operation(record : Bool) -> Unit {
      let started = now_ns()
      let index = next_connection
      next_connection = (index + 1) % connections.length()
      let insert = inserts[index]
      let select = selects[index]
      let scan = scans[index]
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
            options=@protocol.QueryOptions::new(page_size~, skip_metadata=true),
          )
          let mut id = 0
          while true {
            let before = now_ns()
            guard pager.next() is Some(page) else { break }
            if record {
              pages.push(now_ns() - before)
            }
            for index in 0..<page.rows.length() {
              let row = page.row(index)
              assert_eq(row.int("id"), id)
              assert_eq(row.bytes("data"), data)
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
    async fn recorded_operation() -> Unit {
      operation(true)
    }
    let cpu = cpu_ns()
    let start = now_ns()
    ignore(
      @async.all(
        Array::makei(count, _ => recorded_operation),
        max_concurrent=concurrency,
      ),
    )
    let elapsed = now_ns() - start
    let measured_cpu = cpu_ns() - cpu
    assert_eq(samples.length(), count)
    for current in connections {
      assert_eq(current.pending_count(), 0)
      assert_eq(current.waiting_count(), 0)
    }
    guard selects[0].execute([Text(partition)]) is Rows(final_page) else {
      fail("missing final row")
    }
    assert_eq(final_page.row(0).bytes("data"), data)
    print_result(
      mode,
      entropy,
      size,
      compressed,
      count,
      concurrency,
      if mode == "page" {
        page_size
      } else {
        0
      },
      elapsed,
      measured_cpu,
      samples,
      pages,
      version,
      connections.length(),
    )
  })
}

///|
// 嵌套既有作用域保证部分建连失败也关闭已打开连接，并保持旧基线 API 兼容。
async fn with_bench_connections(
  config : @client.ConnectionBuilder,
  remaining : Int32,
  connections : Array[@client.Connection],
  body : async (Array[@client.Connection]) -> Unit,
) -> Unit {
  if remaining == 0 {
    body(connections)
  } else {
    @client.with_connection_builder(config~, connection => {
      connections.push(connection)
      defer ignore(connections.pop())
      with_bench_connections(config, remaining - 1, connections, body)
    })
  }
}

///|
async fn main {
  benchmark() catch {
    @client.Server(server) => fail("server \{server.code}: \{server.message}")
    @client.Configuration(message) | @client.Unexpected(message) =>
      fail(message)
    error => raise error
  }
}
