# 按需 Schema 元数据

[文档目录](README.md) · [Schema agreement](schema-agreement.md) · [开发分支接口](development-api.md)

本页适用于**尚未发布的开发分支**。已发布的 0.2.0 不包含这些接口。

## 读取与范围

`Session.schema_metadata(options?, deadline?)` 按需返回 `SchemaSnapshot`。它从同一协调连接读取 `system_schema.keyspaces`、`tables`、`views`、`columns` 和 `types`，包括 keyspace 的复制配置、普通表和物化视图、列、按位置排列的复合分区键和聚簇键，以及保留字段顺序的 UDT 定义。视图通过 `base_table` 标识原表。列和 UDT 字段的 `cql_type` 保留服务端 CQL 类型字符串，例如 `frozen<tuple<text, int>>`，不转换成协议结果列的类型对象。

`SchemaOptions::new(keyspaces=["app"])` 只读取指定 keyspace；空数组读取这五张目录表中的全部 keyspace。过滤使用绑定值，支持大小写和需要引号的名称，不把名称拼入 CQL。目录不包含索引、函数、聚合、触发器、表选项或 `system_virtual_schema`，不能用它导出完整数据库建表脚本。

快照提供 `keyspaces()`、`tables(keyspace?)`、`user_types(keyspace?)`、`table(keyspace, name)` 和 `user_type(keyspace, name)`。返回的数组与复制配置 Map 均为独立副本，修改它们不会改变快照或 Session 缓存。`schema_version()`、`coordinator()` 和 `loaded_at()` 分别记录读取版本、来源节点和本进程单调时钟的读取时刻；缓存命中不会更新读取时刻。

## 上限与失败

所有过滤和上限在构造 `SchemaOptions` 时冻结：

| 参数 | 默认值 | 含义 |
| --- | --- | --- |
| `max_keyspaces` | 128 | keyspace 数量及过滤名称数量 |
| `max_tables` | 4096 | 普通表与视图的合计数量 |
| `max_columns` | 65536 | 所有表和视图列的合计数量 |
| `max_types` | 4096 | UDT 数量 |
| `max_fields` | 65536 | UDT 字段合计数量 |
| `max_bytes` | 16777216 | 目录文本的累计预算，每个保存的字符串按 UTF-8 字节数加 16 字节计费 |

每次目录请求使用 128 行分页；页和协议帧仍受连接原有接收限制。字节预算控制保存的目录文本，不是进程堆内存的精确计量；返回副本会另占内存。Session 只缓存最近一组过滤和上限的快照，不随不同选项累计缓存。

非法上限、空名称或重复过滤在发请求前返回 `Configuration`。读取阶段使用 `SchemaMetadataError(stage, cause)`：`stage` 为具体目录表、`version` 或 `changed`，`cause` 保留权限错误、超时或目录结构错误。指定 keyspace 缺失、重复或孤立的表／列／UDT、缺少主键、键位置断裂、UDT 字段名与类型数量不符、超过上限均整体失败，不返回部分快照。无权限时明确返回服务端错误，不把失败解释为空目录；普通业务查询仍可独立使用。

一次读取、所有分页、缓存等待和变更重试共享同一 Deadline，默认沿用 Session 操作超时。等待并发读取占用现有 Session 等待数量和字节额度；超时阶段为 `WaitingSchema`，取消后归还额度。

## 缓存与变更

同一 Session 的读取由互斥区合并，首次成功后后续调用复用快照；每次调用仍查询当前协调节点的 `schema_version`，以发现遗漏事件及未启用发现时的变更。加载前后版本必须一致，控制连接事件／刷新代次也必须不变，否则最多重新加载三次。持续变化返回 `SchemaMetadataError("changed", ...)`；总 Deadline 可更早结束读取。

启用发现时，控制连接收到事件即标记失效，事件去抖与后续目录读取共同合并刷新。事件不会主动拉取整份目录。未启用发现时，可调用 `invalidate_schema()` 显式失效；它也适用于应用已知 schema 改变的情况。关闭 Session 会释放缓存；已取得的旧快照仍可读取。

读取版本一致只代表所选协调节点上的目录自洽，不代表集群已经收敛。需要 DDL 后跨节点使用新表或 UDT 时，先按 [schema agreement](schema-agreement.md) 等待，再读取目录或准备语句。

## 运行与独立核对

[完整只读示例](../cmd/schema/main.mbt)通过 `CQL_HOST`、`CQL_PORT`、`CQL_USERNAME`、`CQL_PASSWORD`、`CQL_COMPRESSION` 连接实例。`CQL_SCHEMA_KEYSPACES` 可指定逗号分隔的 keyspace，未设置时读取全部；`CQL_SCHEMA_REPORT` 可指定 JSON 输出文件。成功后输出 `PASS complete schema snapshot`，并断言排空后后台任务为零。

```sh
moon run cmd/schema
```

[独立对照脚本](../scripts/schema_reference.py)会重建专用 **mooncql_schema_a**、**mooncql_schema_b**，需要对应 DDL 权限，只能指向测试实例：

```sh
python -m pip install -r scripts/requirements-reference.txt
python scripts/schema_reference.py
```

脚本逐项比较公共接口、`system_schema` 和 Cassandra Python Driver 3.30.0 的结果，覆盖过滤、复合主键、倒序聚簇键、静态列、嵌套 UDT／tuple／map，以及 ALTER UDT 和 ALTER TABLE 后的目录。快照、工具链和结果报告写入 `.artifacts/schema-reference-*`，CI 在认证与压缩四组合中运行并归档。确定性 TCP 回归另覆盖分页、数量和字节边界、权限失败、事件突发、版本变化、并发合并、取消与迟到响应。
