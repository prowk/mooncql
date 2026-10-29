///|
fn catalog_rows(
  columns : Array[(String, Int32)],
  rows : Array[Array[@types.Value]],
  state? : Bytes,
) -> Bytes raise {
  let writer = @codec.Writer::new()
  writer.i32(2)
  writer.i32(if state is Some(_) { 3 } else { 1 })
  writer.i32(columns.length())
  if state is Some(_) {
    writer.bytes(state)
  }
  writer.string("system_schema")
  writer.string("fixture")
  for (name, code) in columns {
    writer.string(name)
    writer.u16(code)
    if code == 32 {
      writer.u16(13)
    }
    if code == 33 {
      writer.u16(13)
      writer.u16(13)
    }
  }
  writer.i32(rows.length())
  for row in rows {
    for value in row {
      @types.write_value(writer, value)
    }
  }
  writer.to_bytes()
}

///|
fn schema_fixture(
  cql : String,
  mode~ : String = "normal",
  changed~ : Bool = false,
  second_page~ : Bool = false,
) -> Bytes raise {
  if cql.contains("system_schema.keyspaces") {
    let base : Array[@types.Value] = [
      Text("ks"),
      Boolean(true),
      MapValue([
        (Text("class"), Text("SimpleStrategy")),
        (Text("replication_factor"), Text("1")),
      ]),
    ]
    let rows = if mode == "missing-keyspace" {
      []
    } else if mode == "duplicate-keyspace" {
      [base, base]
    } else if mode == "two-keyspaces" {
      [
        base,
        [
          Text("other"),
          Boolean(true),
          MapValue([(Text("class"), Text("SimpleStrategy"))]),
        ],
      ]
    } else {
      [base]
    }
    return catalog_rows(
      [("keyspace_name", 13), ("durable_writes", 4), ("replication", 33)],
      rows,
    )
  }
  if cql.contains("system_schema.tables") {
    return catalog_rows([("keyspace_name", 13), ("table_name", 13)], [
      [Text("ks"), Text("events")],
    ])
  }
  if cql.contains("system_schema.views") {
    return catalog_rows(
      [("keyspace_name", 13), ("view_name", 13), ("base_table_name", 13)],
      [[Text("ks"), Text("events_by_id"), Text("events")]],
    )
  }
  if cql.contains("system_schema.columns") {
    let rows : Array[Array[@types.Value]] = [
      [
        Text("ks"),
        Text("events"),
        Text("payload"),
        Text(if mode == "invalid-kind" { "unsupported" } else { "regular" }),
        Integer(-1),
        Text("frozen<address>"),
        Text("none"),
      ],
      [
        Text("ks"),
        Text("events"),
        Text("day"),
        Text("partition_key"),
        Integer(if mode == "bad-position" { 2 } else { 1 }),
        Text("int"),
        Text("none"),
      ],
      [
        Text("ks"),
        Text("events"),
        Text("tenant"),
        Text("partition_key"),
        Integer(0),
        Text("text"),
        Text("none"),
      ],
      [
        Text("ks"),
        Text("events"),
        Text("id"),
        Text("clustering"),
        Integer(0),
        Text("bigint"),
        Text("desc"),
      ],
      [
        Text("ks"),
        Text("events"),
        Text("note"),
        Text("static"),
        Integer(-1),
        Text("text"),
        Text("none"),
      ],
      [
        Text("ks"),
        Text("events_by_id"),
        Text("id"),
        Text("partition_key"),
        Integer(2),
        Text("bigint"),
        Text("none"),
      ],
      [
        Text("ks"),
        Text("events_by_id"),
        Text("tenant"),
        Text("partition_key"),
        Integer(0),
        Text("text"),
        Text("none"),
      ],
      [
        Text("ks"),
        Text("events_by_id"),
        Text("day"),
        Text("partition_key"),
        Integer(1),
        Text("int"),
        Text("none"),
      ],
    ]
    if changed {
      rows.push([
        Text("ks"),
        Text("events"),
        Text("extra"),
        Text("regular"),
        Integer(-1),
        Text("text"),
        Text("none"),
      ])
    }
    let columns = [
      ("keyspace_name", 13),
      ("table_name", 13),
      ("column_name", 13),
      ("kind", 13),
      ("position", 9),
      ("type", 13),
      ("clustering_order", 13),
    ]
    if mode == "missing-columns" {
      return catalog_rows(columns, [])
    }
    if mode == "paging" {
      return if second_page {
        catalog_rows(columns, rows[3:].to_owned())
      } else {
        catalog_rows(columns, rows[:3].to_owned(), state=b"next")
      }
    }
    return catalog_rows(columns, rows)
  }
  if cql.contains("system_schema.types") {
    let names : Array[@types.Value] = [Text("street"), Text("pair")]
    let types : Array[@types.Value] = [
      Text("text"),
      Text("frozen<tuple<text, int>>"),
    ]
    if changed {
      names.push(Text("country"))
      types.push(Text("text"))
    }
    if mode == "bad-udt" {
      ignore(types.pop())
    }
    let rows : Array[Array[@types.Value]] = [
      [Text("ks"), Text("address"), ListValue(names), ListValue(types)],
    ]
    if mode == "two-types" {
      rows.push([
        Text("ks"),
        Text("other_type"),
        ListValue([Text("x")]),
        ListValue([Text("int")]),
      ])
    }
    return catalog_rows(
      [
        ("keyspace_name", 13),
        ("type_name", 13),
        ("field_names", 32),
        ("field_types", 32),
      ],
      rows,
    )
  }
  fail("unexpected catalog query")
}

///|
fn schema_filter(request : @protocol.MessageEnvelope) -> Bool raise {
  let reader = @codec.Reader::new(request.body)
  let cql = reader.long_string()
  if !cql.contains("system_schema.") {
    return false
  }
  assert_true(cql.contains(" WHERE keyspace_name IN ?"))
  ignore(reader.u16())
  let flags = reader.i32()
  assert_true((flags & 1) != 0)
  assert_eq(reader.u16(), 1)
  assert_eq(
    @types.decode_value(List(Varchar), reader.bytes()),
    @types.Value::ListValue([Text("ks")]),
  )
  assert_eq(reader.i32(), 128)
  (flags & 8) != 0
}

///|
async test "schema metadata freezes filter paginates sorts keys coalesces readers and isolates returned containers" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let seen : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let release : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let counts = [0, 0]
      let phase = [false]
      let worker = group.spawn(() => {
        let (tcp, _) = server.accept()
        let peer = Peer::new(tcp)
        defer peer.close()
        handshake(peer)
        while true {
          let request = Some(receive(peer)) catch { _ => None }
          guard request is Some(request) else { return }
          let cql = @codec.Reader::new(request.body).long_string()
          if cql.contains("schema_version FROM") {
            counts[0] += 1
            if counts[0] == 1 {
              seen.put(())
              release.get()
            }
            respond(
              peer,
              request.header.stream,
              8,
              schema_version_result(
                Some(
                  if phase[0] {
                    b"bbbbbbbbbbbbbbbb"
                  } else {
                    b"aaaaaaaaaaaaaaaa"
                  },
                ),
              ),
            )
          } else {
            counts[1] += 1
            respond(
              peer,
              request.header.stream,
              8,
              schema_fixture(
                cql,
                mode="paging",
                changed=phase[0],
                second_page=schema_filter(request),
              ),
            )
          }
        }
      })
      @client.with_session_builder(
        config=@client.SessionBuilder::new(
          connection=@client.ConnectionBuilder::new(port=server.addr.port()),
        ),
        session => {
          let keys = ["ks"]
          let options = @client.SchemaOptions::new(keyspaces=keys)
          @async.with_task_group(requests => {
            let owner = requests.spawn(() => session.schema_metadata(options~))
            seen.get()
            keys[0] = "mutated"
            let followers = Array::makei(5, _ => {
              requests.spawn(() => session.schema_metadata(options~))
            })
            while session.waiting_count() != 5 {
              @async.pause()
            }
            followers[0].cancel()
            ignore(followers[0].wait()) catch {
              _ => ()
            }
            assert_eq(session.waiting_count(), 4)
            release.put(())
            let snapshot = owner.wait()
            for index in 1..<5 {
              assert_eq(
                followers[index].wait().schema_version(),
                snapshot.schema_version(),
              )
            }
            assert_eq(counts, [6, 6])
            assert_eq(options.keyspaces(), ["ks"])
            let table = snapshot.table("ks", "events").unwrap()
            assert_eq(table.partition_key.map(column => column.name), [
              "tenant", "day",
            ])
            assert_eq(table.clustering_key[0].name, "id")
            assert_eq(table.clustering_key[0].clustering_order, "desc")
            assert_eq(
              snapshot.table("ks", "events_by_id").unwrap().base_table,
              Some("events"),
            )
            table.columns.clear()
            table.partition_key.clear()
            snapshot.keyspaces()[0].replication["class"] = "changed"
            snapshot.user_types()[0].fields.clear()
            assert_eq(
              snapshot.table("ks", "events").unwrap().columns.length(),
              5,
            )
            assert_eq(
              snapshot.keyspaces()[0].replication.get("class"),
              Some("SimpleStrategy"),
            )
            assert_eq(
              snapshot.user_type("ks", "address").unwrap().fields[1].1,
              "frozen<tuple<text, int>>",
            )
            phase[0] = true
            let refreshed = session.schema_metadata(options~)
            assert_eq(
              refreshed.table("ks", "events").unwrap().columns.length(),
              6,
            )
            assert_eq(
              refreshed.user_type("ks", "address").unwrap().fields.length(),
              3,
            )
            assert_eq(
              snapshot.user_type("ks", "address").unwrap().fields.length(),
              2,
            )
            session.invalidate_schema()
            ignore(session.schema_metadata(options~))
            assert_eq(counts[1], 18)
          })
          assert_eq(session.resources().waiting, 0)
          assert_eq(session.resources().waiting_bytes, 0L)
          session.close()
          assert_eq(session.resources().active, 0)
        },
      )
      worker.wait()
    })
  })
}

///|
async test "schema metadata refuses missing duplicated malformed and over-limit catalogs without poisoning ordinary requests" {
  let cases = [
    ("missing-keyspace", @client.SchemaOptions::new(keyspaces=["ks"])),
    ("duplicate-keyspace", @client.SchemaOptions::new(keyspaces=["ks"])),
    ("missing-columns", @client.SchemaOptions::new(keyspaces=["ks"])),
    ("bad-position", @client.SchemaOptions::new(keyspaces=["ks"])),
    ("invalid-kind", @client.SchemaOptions::new(keyspaces=["ks"])),
    ("bad-udt", @client.SchemaOptions::new(keyspaces=["ks"])),
    ("two-keyspaces", @client.SchemaOptions::new(max_keyspaces=1)),
    ("normal", @client.SchemaOptions::new(keyspaces=["ks"], max_tables=1)),
    ("normal", @client.SchemaOptions::new(keyspaces=["ks"], max_columns=7)),
    ("two-types", @client.SchemaOptions::new(keyspaces=["ks"], max_types=1)),
    ("normal", @client.SchemaOptions::new(keyspaces=["ks"], max_fields=1)),
    ("normal", @client.SchemaOptions::new(keyspaces=["ks"], max_bytes=256)),
    ("denied", @client.SchemaOptions::new(keyspaces=["ks"])),
  ]
  for (mode, options) in cases {
    @async.with_timeout(5000, () => {
      @async.with_task_group(group => {
        let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
        defer server.close()
        let worker = group.spawn(() => {
          let (tcp, _) = server.accept()
          let peer = Peer::new(tcp)
          defer peer.close()
          handshake(peer)
          while true {
            let request = Some(receive(peer)) catch { _ => None }
            guard request is Some(request) else { return }
            let cql = @codec.Reader::new(request.body).long_string()
            if cql == "ordinary" {
              respond(peer, request.header.stream, 8, b"\x00\x00\x00\x01")
            } else if cql.contains("schema_version FROM") {
              respond(
                peer,
                request.header.stream,
                8,
                schema_version_result(Some(b"aaaaaaaaaaaaaaaa")),
              )
            } else if mode == "denied" {
              let error = @codec.Writer::new()
              error.i32(0x2100)
              error.string("schema access denied")
              respond(peer, request.header.stream, 0, error.to_bytes())
            } else {
              respond(
                peer,
                request.header.stream,
                8,
                schema_fixture(cql, mode~),
              )
            }
          }
        })
        @client.with_session_builder(
          config=@client.SessionBuilder::new(
            connection=@client.ConnectionBuilder::new(port=server.addr.port()),
          ),
          session => {
            assert_true(
              try {
                ignore(session.schema_metadata(options~))
                false
              } catch {
                @client.SchemaMetadataError(_, _) => true
                _ => false
              },
            )
            assert_true(session.query("ordinary") is Void)
            assert_eq(session.resources().active, 0)
            assert_eq(session.resources().waiting, 0)
          },
        )
        worker.wait()
      })
    })
  }
}
