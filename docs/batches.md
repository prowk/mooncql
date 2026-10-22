# BATCH 的使用边界

[文档目录](README.md) · [入门教程](getting-started.md)

main 提供 `Connection.batch(statements, kind?, options?, deadline?)`。每条语句使用 `BatchStatement.Query(cql, values)`，或由当前连接的 `Prepared.bind_batch(values)` 创建；预处理语句 ID 属于准备它的物理连接，不能跨连接或恢复代次复用。可运行例子在 `cmd/integration/v5.mbt`，执行 `moon run cmd/integration` 会同时校验普通语句、预处理绑定、unlogged 和 counter 批处理。

| kind | 适用场景与服务端语义 |
| --- | --- |
| Logged（默认） | 需要 batchlog 保证最终完整应用的一组写入；跨分区时有额外开销，不保证跨分区隔离 |
| Unlogged | 合适的同分区写入；不使用 batchlog，跨分区失败可能只应用部分写入 |
| Counter | counter 更新；更新本身不幂等，结果未知时不可直接重放 |

同分区更新具有分区内隔离语义。BATCH 只包含写语句，不用于 SELECT，也不提供一般关系数据库事务能力。默认时间戳可能相同，语句排列顺序不保证最终覆盖顺序；需要有序覆盖时应在应用中明确时间戳。具体服务端约束见 [Apache Cassandra CQL BATCH](https://cassandra.apache.org/doc/stable/cassandra/developing/cql/dml.html#batch)。

示例假设当前连接已准备好 `app.events(device int, id int, message text, PRIMARY KEY (device, id))`：

```moonbit
connection.batch(
  [
    Query("INSERT INTO app.events (device,id,message) VALUES (?,?,?)", [
      Integer(42), Integer(1), Text("开始"),
    ]),
    Query("INSERT INTO app.events (device,id,message) VALUES (?,?,?)", [
      Integer(42), Integer(2), Text("完成"),
    ]),
  ],
  kind=Unlogged,
  options=@protocol.QueryOptions::new(consistency=LocalQuorum),
)
```

成功时 Connection.batch 要求服务端返回 VOID。0.2.0 的 Session 低层入口是 `session.request(protocol.batch(...))`，返回 Response，调用方应处理 Failure；当前开发分支另外提供不依赖业务侧物理连接的 `Session.batch`／`batch_with_info` 和逻辑批处理绑定，详见[开发分支接口](development-api.md)。需要 LWT 返回列时使用查询或预处理接口，参见 [条件写入](conditional-writes.md)。

BATCH 不自动重放，也不自动修复其中的 UNPREPARED。断线、超时或取消后，服务端可能已经执行部分或全部写入，需按业务键读取并核对结果。重新准备后重提整个批次前，应由应用确认所有操作都适合重放；counter、LWT 和集合追加尤其需要独立处理。请求级 tracing 和 custom payload 通过 options.request_options 发送；要保留完整执行信息，参见 [with_info 接口](execution-info.md)。

批处理拒绝空语句列表，以及 page_size、paging_state、skip_metadata 和 value_names 等仅适用于查询的选项。timestamp 单位为微秒，now_in_seconds 单位为秒；两者应保持各自语义。客户端仍受帧大小、在途字节和截止时间限制，服务端另有批大小等限制。持续高吞吐写入可使用有界并发的独立请求，批次大小应按实际延迟与负载测量。
