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
  )
  @client.with_connection(config~, connection => {
    guard connection.query("SELECT * FROM mooncql_test.interop WHERE id=1")
      is Rows(page) else {
      fail("expected Python row")
    }
    assert_eq(page.rows.length(), 1)
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
    ignore(
      connection.query("UPDATE mooncql_test.interop SET message=? WHERE id=?", values=[
        Text("MoonBit verified Python"),
        Integer(1),
      ]),
    )
    println("MoonBit verified Python scalar, collection, tuple and UDT values")
  })
}
