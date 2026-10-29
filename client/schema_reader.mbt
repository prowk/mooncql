///|
async fn schema_catalog(
  connection : Connection,
  table : String,
  projection : String,
  options : SchemaOptions,
  deadline : Deadline,
  consume : (@protocol.Page, Int32) -> Unit raise,
) -> Unit {
  let (suffix, values) : (String, Array[@types.Value]) = if options.names.is_empty() {
    ("", [])
  } else {
    (
      " WHERE keyspace_name IN ?",
      [ListValue(options.names.map(name => @types.Value::Text(name)))],
    )
  }
  let pages = connection.pages(
    "SELECT " + projection + " FROM system_schema." + table + suffix,
    values~,
    options=@protocol.QueryOptions::new(page_size=128),
  )
  try {
    while pages.next(deadline~) is Some(page) {
      for row in 0..<page.rows.length() {
        consume(page, row)
      }
    }
  } catch {
    error => raise SchemaMetadataError(table, error)
  }
}

///|
async fn load_schema(
  connection : Connection,
  version : Bytes,
  options : SchemaOptions,
  deadline : Deadline,
) -> SchemaSnapshot {
  let budget = SchemaBudget::{ limit: options.max_bytes, used: 0, }
  let keyspaces : Map[String, SchemaKeyspace] = Map([])
  schema_catalog(
    connection,
    "keyspaces",
    "keyspace_name,durable_writes,replication",
    options,
    deadline,
    (page, row) => {
      if keyspaces.length() >= options.max_keyspaces {
        raise Configuration("schema metadata exceeds max_keyspaces")
      }
      let name = schema_text(page, row, "keyspace_name", budget)
      schema_selected(options, name)
      if keyspaces.contains(name) {
        raise Unexpected("duplicate keyspace metadata")
      }
      guard page.get(row, "durable_writes") is Boolean(durable_writes) else {
        raise Unexpected("missing durable_writes")
      }
      guard page.get(row, "replication") is MapValue(entries) &&
        !entries.is_empty() else {
        raise Unexpected("missing replication metadata")
      }
      let replication : Map[String, String] = Map([])
      for (key, value) in entries {
        guard key is Text(key) &&
          value is Text(value) &&
          !key.is_empty() &&
          !value.is_empty() &&
          !replication.contains(key) else {
          raise Unexpected("invalid replication metadata")
        }
        budget.charge(key)
        budget.charge(value)
        replication[key] = value
      }
      if !replication.contains("class") {
        raise Unexpected("missing replication class")
      }
      keyspaces[name] = { name, durable_writes, replication, }
    },
  )
  for name in options.names {
    if !keyspaces.contains(name) {
      raise SchemaMetadataError(
        "keyspaces",
        Unexpected("requested keyspace is missing"),
      )
    }
  }
  let tables : Map[String, SchemaTable] = Map([])
  schema_catalog(
    connection,
    "tables",
    "keyspace_name,table_name",
    options,
    deadline,
    (page, row) => {
      if tables.length() >= options.max_tables {
        raise Configuration("schema metadata exceeds max_tables")
      }
      let keyspace = schema_text(page, row, "keyspace_name", budget)
      let name = schema_text(page, row, "table_name", budget)
      schema_selected(options, keyspace)
      let owner = schema_owner(keyspace, name)
      if !keyspaces.contains(keyspace) || tables.contains(owner) {
        raise Unexpected("orphan or duplicate table metadata")
      }
      tables[owner] = {
        keyspace,
        name,
        base_table: None,
        columns: [],
        partition_key: [],
        clustering_key: [],
      }
    },
  )
  // 视图同样出现在 columns 中，必须显式识别，不能把视图列误当作缺失表。
  schema_catalog(
    connection,
    "views",
    "keyspace_name,view_name,base_table_name",
    options,
    deadline,
    (page, row) => {
      if tables.length() >= options.max_tables {
        raise Configuration("schema metadata exceeds max_tables")
      }
      let keyspace = schema_text(page, row, "keyspace_name", budget)
      let name = schema_text(page, row, "view_name", budget)
      let base_table = schema_text(page, row, "base_table_name", budget)
      schema_selected(options, keyspace)
      let owner = schema_owner(keyspace, name)
      guard tables.get(schema_owner(keyspace, base_table)) is Some(base) &&
        base.base_table is None else {
        raise Unexpected("view base table metadata is missing")
      }
      if tables.contains(owner) {
        raise Unexpected("duplicate view metadata")
      }
      tables[owner] = {
        keyspace,
        name,
        base_table: Some(base_table),
        columns: [],
        partition_key: [],
        clustering_key: [],
      }
    },
  )
  let columns : Map[String, Map[String, SchemaColumn]] = Map([])
  let mut column_count = 0
  schema_catalog(
    connection,
    "columns",
    "keyspace_name,table_name,column_name,kind,position,type,clustering_order",
    options,
    deadline,
    (page, row) => {
      if column_count >= options.max_columns {
        raise Configuration("schema metadata exceeds max_columns")
      }
      let keyspace = schema_text(page, row, "keyspace_name", budget)
      let table = schema_text(page, row, "table_name", budget)
      let name = schema_text(page, row, "column_name", budget)
      schema_selected(options, keyspace)
      let owner = schema_owner(keyspace, table)
      if !tables.contains(owner) {
        raise Unexpected("column has no table or view metadata")
      }
      let cql_type = schema_text(page, row, "type", budget)
      let kind : SchemaColumnKind = match
        schema_text(page, row, "kind", budget) {
        "partition_key" => PartitionKey
        "clustering" => Clustering
        "static" => Static
        "regular" => Regular
        _ => raise Unexpected("unknown schema column kind")
      }
      guard page.get(row, "position") is Integer(position) else {
        raise Unexpected("missing column position")
      }
      let clustering_order = schema_text(page, row, "clustering_order", budget)
      if kind == Clustering {
        if position < 0 ||
          (clustering_order != "asc" && clustering_order != "desc") {
          raise Unexpected("invalid clustering metadata")
        }
      } else if kind == PartitionKey {
        if position < 0 || clustering_order != "none" {
          raise Unexpected("invalid partition key metadata")
        }
      } else if position != -1 || clustering_order != "none" {
        raise Unexpected("invalid regular or static column metadata")
      }
      let entries = match columns.get(owner) {
        Some(entries) => entries
        None => {
          let entries : Map[String, SchemaColumn] = Map([])
          columns[owner] = entries
          entries
        }
      }
      if entries.contains(name) {
        raise Unexpected("duplicate column metadata")
      }
      entries[name] = { name, cql_type, kind, position, clustering_order, }
      column_count += 1
    },
  )
  let table_data = []
  for owner, table in tables {
    guard columns.get(owner) is Some(entries) && !entries.is_empty() else {
      raise SchemaMetadataError(
        "columns",
        Unexpected("table columns are missing"),
      )
    }
    let all_columns = entries.values().to_array()
    all_columns.sort_by((left, right) => left.name.compare(right.name))
    let partition_key = all_columns.filter(column => column.kind == PartitionKey)
    let clustering_key = all_columns.filter(column => column.kind == Clustering)
    partition_key.sort_by((left, right) => left.position.compare(right.position))
    clustering_key.sort_by((left, right) => {
      left.position.compare(right.position)
    })
    if partition_key.is_empty() {
      raise SchemaMetadataError(
        "columns",
        Unexpected("table partition key is missing"),
      )
    }
    for key in [partition_key, clustering_key] {
      for index, column in key {
        if column.position != index {
          raise SchemaMetadataError(
            "columns",
            Unexpected("key positions are not contiguous"),
          )
        }
      }
    }
    table_data.push({
      ..table,
      columns: all_columns,
      partition_key,
      clustering_key,
    })
  }
  table_data.sort_by((left, right) => {
    schema_owner(left.keyspace, left.name).compare(
      schema_owner(right.keyspace, right.name),
    )
  })
  let user_types : Map[String, SchemaUserType] = Map([])
  let mut field_count = 0
  schema_catalog(
    connection,
    "types",
    "keyspace_name,type_name,field_names,field_types",
    options,
    deadline,
    (page, row) => {
      if user_types.length() >= options.max_types {
        raise Configuration("schema metadata exceeds max_types")
      }
      let keyspace = schema_text(page, row, "keyspace_name", budget)
      let name = schema_text(page, row, "type_name", budget)
      schema_selected(options, keyspace)
      let owner = schema_owner(keyspace, name)
      if !keyspaces.contains(keyspace) || user_types.contains(owner) {
        raise Unexpected("orphan or duplicate UDT metadata")
      }
      guard page.get(row, "field_names") is ListValue(names) &&
        page.get(row, "field_types") is ListValue(types) &&
        !names.is_empty() &&
        names.length() == types.length() else {
        raise Unexpected("incomplete UDT definition")
      }
      if names.length() > options.max_fields - field_count {
        raise Configuration("schema metadata exceeds max_fields")
      }
      let seen : Map[String, Bool] = Map([])
      let fields = []
      for index, item in names {
        guard item is Text(field) &&
          types[index] is Text(typ) &&
          !field.is_empty() &&
          !typ.is_empty() &&
          !field.contains("\u0000") &&
          !typ.contains("\u0000") &&
          !seen.contains(field) else {
          raise Unexpected("invalid UDT field definition")
        }
        budget.charge(field)
        budget.charge(typ)
        fields.push((field, typ))
        seen[field] = true
      }
      field_count += fields.length()
      user_types[owner] = { keyspace, name, fields, }
    },
  )
  let keyspace_data = keyspaces.values().to_array()
  keyspace_data.sort_by((left, right) => left.name.compare(right.name))
  let type_data = user_types.values().to_array()
  type_data.sort_by((left, right) => {
    schema_owner(left.keyspace, left.name).compare(
      schema_owner(right.keyspace, right.name),
    )
  })
  {
    version,
    origin: Endpoint::new(
      host=connection.config.host,
      port=connection.config.port,
    ),
    read_at: @async.now(),
    keyspace_data,
    table_data,
    type_data,
  }
}
