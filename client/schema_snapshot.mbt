///|
/// 目录读取要求完整成功；stage 标记读取阶段，cause 保留权限／协议等原始错误。
pub(all) suberror SchemaMetadataError {
  SchemaMetadataError(String, Error)
}

///|
/// 所有过滤和上限在构造时冻结；空 keyspaces 表示读取全部可见 keyspace。
pub struct SchemaOptions {
  names : Array[String]
  max_keyspaces : Int32
  max_tables : Int32
  max_columns : Int32
  max_types : Int32
  max_fields : Int32
  max_bytes : Int32
  identity : Bytes
}

///|
/// 冻结 keyspace 过滤和数量／字节预算；默认目录文本上限十六 MiB，非法参数立即报错。
pub fn SchemaOptions::new(
  keyspaces~ : Array[String] = [],
  max_keyspaces~ : Int32 = 128,
  max_tables~ : Int32 = 4096,
  max_columns~ : Int32 = 65536,
  max_types~ : Int32 = 4096,
  max_fields~ : Int32 = 65536,
  max_bytes~ : Int32 = 16777216,
) -> SchemaOptions raise DriverError {
  if max_keyspaces < 1 ||
    max_keyspaces > 65536 ||
    max_tables < 1 ||
    max_tables > 65536 ||
    max_columns < 1 ||
    max_columns > 1000000 ||
    max_types < 1 ||
    max_types > 65536 ||
    max_fields < 1 ||
    max_fields > 1000000 ||
    max_bytes < 256 ||
    max_bytes > 1073741824 ||
    keyspaces.length() > max_keyspaces {
    raise Configuration("invalid schema metadata limits")
  }
  let names = keyspaces.copy()
  names.sort_by((left, right) => left.compare(right))
  let writer = @codec.Writer::new()
  writer.i32(names.length())
  let mut total = 0
  for index, name in names {
    let length = @utf8.encode(name).length()
    if length == 0 ||
      length > 65535 ||
      name.contains("\u0000") ||
      (index > 0 && names[index - 1] == name) {
      raise Configuration("invalid or duplicate schema keyspace filter")
    }
    total += length + 4
    if total > max_bytes {
      raise Configuration("schema filter exceeds byte limit")
    }
    writer.long_string(name)
  }
  for
    limit in [
      max_keyspaces, max_tables, max_columns, max_types, max_fields, max_bytes,
    ] {
    writer.i32(limit)
  }
  {
    names,
    max_keyspaces,
    max_tables,
    max_columns,
    max_types,
    max_fields,
    max_bytes,
    identity: writer.to_bytes(),
  }
}

///|
/// 返回排序后的过滤名称副本，空数组表示不限制 keyspace。
pub fn SchemaOptions::keyspaces(self : SchemaOptions) -> Array[String] {
  self.names.copy()
}

///|
pub(all) enum SchemaColumnKind {
  PartitionKey
  Clustering
  Static
  Regular
} derive(Eq, @debug.Debug)

///|
pub extend SchemaColumnKind with Eq::{equal, not_equal}

///|
pub extend SchemaColumnKind with @debug.Debug::{to_repr}

///|
pub impl ToJson for SchemaColumnKind with fn to_json(self : SchemaColumnKind) -> Json {
  Json(
    match self {
      PartitionKey => "partition_key"
      Clustering => "clustering"
      Static => "static"
      Regular => "regular"
    },
  )
}

///|
pub extend SchemaColumnKind with ToJson::{to_json}

///|
pub(all) struct SchemaColumn {
  name : String
  cql_type : String
  kind : SchemaColumnKind
  position : Int32
  clustering_order : String
} derive(ToJson)

///|
pub extend SchemaColumn with ToJson::{to_json}

///|
pub(all) struct SchemaTable {
  keyspace : String
  name : String
  base_table : String?
  columns : Array[SchemaColumn]
  partition_key : Array[SchemaColumn]
  clustering_key : Array[SchemaColumn]
} derive(ToJson)

///|
pub extend SchemaTable with ToJson::{to_json}

///|
pub(all) struct SchemaKeyspace {
  name : String
  durable_writes : Bool
  replication : Map[String, String]
} derive(ToJson)

///|
pub extend SchemaKeyspace with ToJson::{to_json}

///|
pub(all) struct SchemaUserType {
  keyspace : String
  name : String
  fields : Array[(String, String)]
} derive(ToJson)

///|
pub extend SchemaUserType with ToJson::{to_json}

///|
/// 快照的容器不直接暴露；每次访问返回独立副本，修改副本不会改变本快照或缓存。
pub struct SchemaSnapshot {
  version : Bytes
  origin : Endpoint
  read_at : Int64
  keyspace_data : Array[SchemaKeyspace]
  table_data : Array[SchemaTable]
  type_data : Array[SchemaUserType]
}

///|
fn schema_keyspace_copy(value : SchemaKeyspace) -> SchemaKeyspace {
  let replication : Map[String, String] = Map([])
  for name, setting in value.replication {
    replication[name] = setting
  }
  { ..value, replication, }
}

///|
fn schema_table_copy(value : SchemaTable) -> SchemaTable {
  {
    ..value,
    columns: value.columns.copy(),
    partition_key: value.partition_key.copy(),
    clustering_key: value.clustering_key.copy(),
  }
}

///|
pub fn SchemaSnapshot::schema_version(self : SchemaSnapshot) -> Bytes {
  self.version
}

///|
pub fn SchemaSnapshot::coordinator(self : SchemaSnapshot) -> Endpoint {
  self.origin
}

///|
pub fn SchemaSnapshot::loaded_at(self : SchemaSnapshot) -> Int64 {
  self.read_at
}

///|
pub fn SchemaSnapshot::keyspaces(
  self : SchemaSnapshot,
) -> Array[SchemaKeyspace] {
  self.keyspace_data.map(schema_keyspace_copy)
}

///|
pub fn SchemaSnapshot::tables(
  self : SchemaSnapshot,
  keyspace? : String,
) -> Array[SchemaTable] {
  self.table_data
  .filter(value => keyspace is None || keyspace == Some(value.keyspace))
  .map(schema_table_copy)
}

///|
pub fn SchemaSnapshot::user_types(
  self : SchemaSnapshot,
  keyspace? : String,
) -> Array[SchemaUserType] {
  self.type_data
  .filter(value => keyspace is None || keyspace == Some(value.keyspace))
  .map(value => { ..value, fields: value.fields.copy(), })
}

///|
pub fn SchemaSnapshot::table(
  self : SchemaSnapshot,
  keyspace : String,
  name : String,
) -> SchemaTable? {
  for value in self.table_data {
    if value.keyspace == keyspace && value.name == name {
      return Some(schema_table_copy(value))
    }
  }
  None
}

///|
pub fn SchemaSnapshot::user_type(
  self : SchemaSnapshot,
  keyspace : String,
  name : String,
) -> SchemaUserType? {
  for value in self.type_data {
    if value.keyspace == keyspace && value.name == name {
      return Some({ ..value, fields: value.fields.copy(), })
    }
  }
  None
}

///|
priv struct SchemaBudget {
  limit : Int32
  mut used : Int32
}

///|
fn SchemaBudget::charge(
  self : SchemaBudget,
  value : String,
) -> Unit raise DriverError {
  let bytes = @utf8.encode(value).length()
  if bytes > self.limit - self.used - 16 {
    raise Configuration("schema metadata exceeds byte limit")
  }
  self.used += bytes + 16
}

///|
fn schema_text(
  page : @protocol.Page,
  row : Int32,
  name : String,
  budget : SchemaBudget,
) -> String raise {
  guard page.get(row, name) is Text(value) &&
    !value.is_empty() &&
    !value.contains("\u0000") else {
    raise Unexpected("missing schema text: " + name)
  }
  budget.charge(value)
  value
}

///|
fn schema_owner(keyspace : String, name : String) -> String {
  keyspace + "\u0000" + name
}

///|
fn schema_selected(
  options : SchemaOptions,
  keyspace : String,
) -> Unit raise DriverError {
  if !options.names.is_empty() && !options.names.contains(keyspace) {
    raise Unexpected("server returned schema outside filter")
  }
}

///|
async fn schema_version(connection : Connection, deadline : Deadline) -> Bytes {
  guard connection.query("SELECT schema_version FROM system.local", deadline~)
    is Rows(page) &&
    page.rows.length() == 1 &&
    page.get(0, "schema_version") is Uuid(version) &&
    version.length() == 16 else {
    raise Unexpected("missing schema version")
  }
  version
}
