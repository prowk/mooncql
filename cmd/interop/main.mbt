///|
async fn main {
  let port = match @env.get_env_var("CQL_PORT") {
    Some(s) => @string.parse_int(s)
    None => 9042
  }
  let config = @client.Config::new(
    host=@env.get_env_var("CQL_HOST").unwrap_or("127.0.0.1"),
    port~,
    username?=@env.get_env_var("CQL_USERNAME"),
    password?=@env.get_env_var("CQL_PASSWORD"),
    compression=@env.get_env_var("CQL_COMPRESSION") == Some("lz4"),
  )
  @client.with_connection(config~, connection => {
    guard connection.query("SELECT * FROM mooncql_test.interop WHERE id=1")
      is Rows(page) else {
      fail("expected Python row")
    }
    assert_eq(page.rows.length(), 1)
    let typed = page.row(0)
    assert_eq(typed.text("message"), "Python 中文")
    assert_eq(typed.int64("big"), 9007199254740993L)
    assert_eq(
      typed.uuid("uid").to_string(),
      "00112233-4455-6677-8899-aabbccddeeff",
    )
    assert_eq(typed.date("day").to_string(), "1970-01-02")
    assert_eq(typed.time("clock").to_string(), "00:00:00.123456789")
    assert_eq(typed.decimal("amount").to_plain_string(), "123.45")
    assert_eq(
      typed.varint("huge").to_decimal_string(),
      "1267650600228229401496703205379",
    )
    assert_eq(page.get(0, "message"), @types.Value::Text("Python 中文"))
    assert_eq(page.get(0, "big"), @types.Value::BigInteger(9007199254740993L))
    assert_eq(page.get(0, "payload"), @types.Value::Bytes(b"\x00\xff"))
    assert_eq(page.get(0, "flag"), @types.Value::Boolean(true))
    assert_eq(page.get(0, "real_value"), @types.Value::Real(-1.25))
    assert_eq(page.get(0, "single_value"), @types.Value::Single(1.5F))
    assert_eq(
      page.get(0, "uid"),
      @types.Value::Uuid(
        b"\x00\x11\x22\x33\x44\x55\x66\x77\x88\x99\xaa\xbb\xcc\xdd\xee\xff",
      ),
    )
    assert_eq(
      page.get(0, "time_uid"),
      @types.Value::Uuid(
        b"\xf4\x7a\xc1\x0b\x58\xcc\x11\xcf\xa4\x47\x00\x11\x22\x33\x44\x55",
      ),
    )
    assert_eq(page.get(0, "ip"), @types.Value::Inet(b"\x7f\x00\x00\x01"))
    assert_eq(page.get(0, "day"), @types.Value::Date(1))
    assert_eq(page.get(0, "clock"), @types.Value::Time(123456789L))
    assert_eq(page.get(0, "small"), @types.Value::SmallInteger(-32768))
    assert_eq(page.get(0, "tiny"), @types.Value::TinyInteger(-128))
    assert_eq(page.get(0, "amount"), @types.Value::Decimal(2, b"\x30\x39"))
    assert_eq(
      page.get(0, "huge"),
      @types.Value::VarInt(
        b"\x10\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x03",
      ),
    )
    assert_eq(
      page.get(0, "pair"),
      @types.Value::TupleValue([Text("tuple 中文"), Integer(42)]),
    )
    assert_eq(
      page.get(0, "address"),
      @types.Value::UdtValue([
        ("street", Text("Main 中文")),
        ("zip", Integer(12345)),
      ]),
    )
    assert_eq(
      page.get(0, "tags"),
      @types.Value::SetValue([Text("moon"), Text("中文")]),
    )
    // Python 客户端与数据库可能使用不同宿主机时钟，后续更新显式晚于已存单元格。
    guard connection.query(
        "SELECT writetime(message) AS written_at FROM mooncql_test.interop WHERE id=1",
      )
      is Rows(written) else {
      fail("missing Python cell timestamp")
    }
    let timestamp = written.row(0).int64("written_at")
    assert_true(timestamp < 9223372036854775807L)
    ignore(
      connection.query(
        "UPDATE mooncql_test.interop USING TIMESTAMP ? SET message=? WHERE id=?",
        values=[
          BigInteger(timestamp + 1L),
          Text("MoonBit verified Python"),
          Integer(1),
        ],
      ),
    )
    let payload = Bytes::from_array(
      Array::makei(400000, i => (i % 251).to_byte()),
    )
    guard connection.query(
        "SELECT d,payload FROM mooncql_test.interop_v5 WHERE id=1",
      )
      is Rows(v5) else {
      fail("missing v5 interop row")
    }
    assert_eq(v5.get(0, "d"), @types.Value::Duration(-64, -128, -8192L))
    assert_eq(v5.get(0, "payload"), @types.Value::Bytes(payload))
    guard connection.query(
        "SELECT * FROM mooncql_test.interop_conversions WHERE id=1",
      )
      is Rows(exact) else {
      fail("missing exact conversion row")
    }
    let row = exact.row(0)
    assert_eq(row.date("d").days(), -2147483648)
    assert_eq(row.time("t").nanos(), 86399999999999L)
    assert_eq(row.timestamp("s").millis(), -9223372036854775808L)
    assert_eq(
      row.varint("n").to_decimal_string(),
      "100000000000000000000000000000000000000000000000000000000000000000000000001234567",
    )
    assert_eq(
      row.decimal("m").to_plain_string(),
      "-123456789012345678901234567890.0012300",
    )
    let exact_insert = connection.prepare(
      "INSERT INTO mooncql_test.interop_conversions (id,u,d,t,s,n,m) VALUES (?,?,?,?,?,?,?)",
    )
    ignore(
      exact_insert.execute([
        Integer(2),
        @types.CqlUuid::from_string("00112233-4455-6677-8899-aabbccddeeff").to_value(),
        @types.CqlDate::from_days(2147483647).to_value(),
        @types.CqlTime::from_string("23:59:59.999999999").to_value(),
        @types.CqlTimestamp::from_millis(9223372036854775807L).to_value(),
        @types.CqlVarInt::from_decimal_string(
          "-100000000000000000000000000000000000000000000000000000000000000000000000001234567",
        ).to_value(),
        @types.CqlDecimal::from_string(
          "-123456789012345678901234567890.0012300",
        ).to_value(),
      ]),
    )
    let insert = connection.prepare(
      "INSERT INTO mooncql_test.interop_v5 (id,d,payload) VALUES (?,?,?)",
    )
    ignore(
      insert.execute([
        Integer(2),
        Duration(2147483647, 2147483647, 9223372036854775807L),
        Bytes(payload),
      ]),
    )
    println(
      "MoonBit verified Python scalar, collection, tuple, UDT, duration and large blob values",
    )
  })
}
