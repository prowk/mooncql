///|
struct Place {
  street : String
  coordinate : (Int, String?)
} derive(Eq, @debug.Debug)

///|
fn place_codec() -> @mapping.ValueCodec[Place] raise {
  let number = @mapping.int_codec()
  let text = @mapping.text_codec()
  let optional_text = text.optional()
  let pair = @mapping.ValueCodec::new(
    Tuple([Int, Varchar]),
    (coordinate : (Int, String?), context) => {
      TupleValue([
        context.item(0, number, coordinate.0),
        context.item(1, optional_text, coordinate.1),
      ])
    },
    reader => (reader.item(0).read(number), reader.item(1).read(optional_text)),
  )
  @mapping.ValueCodec::new(
    Udt("mooncql_mapping", "place", [
      ("street", Varchar),
      ("coordinate", pair.cql_type()),
    ]),
    (place : Place, context) => {
      UdtValue([
        ("street", context.field("street", text, place.street)),
        ("coordinate", context.field("coordinate", pair, place.coordinate)),
      ])
    },
    reader => {
      street: reader.field("street").read(text),
      coordinate: reader.field("coordinate").read(pair),
    },
  )
}

///|
async fn main {
  let codec = place_codec()
  let place = { street: "月球大道", coordinate: (7, None), }
  let direct : @types.Value = UdtValue([
    ("street", Text("月球大道")),
    ("coordinate", TupleValue([Integer(7), Null])),
  ])
  let value = codec.encode(place)
  assert_eq(value, direct)
  assert_eq(@types.encode_value(value), @types.encode_value(direct))
  let row_codec = @mapping.RowCodec::new(reader => {
    (
      reader.column("id").read(@mapping.int_codec()),
      reader.column("home").read(codec),
    )
  })
  let page = @protocol.Page::new(
    [
      { keyspace: "mooncql_mapping", table: "events", name: "id", typ: Int, },
      {
        keyspace: "mooncql_mapping",
        table: "events",
        name: "home",
        typ: codec.cql_type(),
      },
    ],
    [[Integer(42), value]],
  )
  assert_eq(row_codec.decode(page.row(0)), (42, place))
  println("PASS explicit mapping, nested UDT/tuple and identical Value bytes")
  if @env.get_env_var("CQL_MAPPING_INTEGRATION") == Some("1") {
    let connection = @client.Config::new(
      host=@env.get_env_var("CQL_HOST").unwrap_or("127.0.0.1"),
      port=@env.get_env_var("CQL_PORT")
        .map(port => @string.parse_int(port))
        .unwrap_or(9042),
      username?=@env.get_env_var("CQL_USERNAME"),
      password?=@env.get_env_var("CQL_PASSWORD"),
      compression=@env.get_env_var("CQL_COMPRESSION") == Some("lz4"),
    )
    @client.with_session(config=@client.SessionConfig::new(connection~), session => {
      ignore(
        session.query(
          "CREATE KEYSPACE IF NOT EXISTS mooncql_mapping WITH replication={'class':'SimpleStrategy','replication_factor':1}",
        ),
      )
      ignore(
        session.query(
          "CREATE TYPE IF NOT EXISTS mooncql_mapping.place (street text, coordinate tuple<int,text>)",
        ),
      )
      ignore(
        session.query(
          "CREATE TABLE IF NOT EXISTS mooncql_mapping.events (id int PRIMARY KEY,home frozen<place>)",
        ),
      )
      let insert = session.prepare(
        "INSERT INTO mooncql_mapping.events (id,home) VALUES (?,?)",
      )
      ignore(insert.execute([Integer(42), value]))
      guard session.query(
          "SELECT id,home FROM mooncql_mapping.events WHERE id=42",
        )
        is Rows(read) else {
        fail("missing mapped row")
      }
      assert_eq(row_codec.decode(read.row(0)), (42, place))
      assert_eq(
        @types.encode_value(read.row(0).value("home")),
        @types.encode_value(direct),
      )
      ignore(session.drain(@client.Deadline::after(5000)))
      assert_eq(session.resources().background_task_handles, 0)
      println(
        "PASS mapped prepared binding, native UDT/tuple result and drained Session",
      )
    })
  }
}
