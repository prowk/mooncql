# 条件写入

[文档目录](README.md) · [入门教程](getting-started.md)

本文适用于 0.2.1。

`Connection.query_conditional` 和 `Prepared.execute_conditional` 返回 `ConditionalResult`。
`applied` 表示本次 IF 条件是否成立；未应用是正常数据库结果，不作为异常。
`page` 保留本次返回的全部列，可在条件失败时读取数据库中的当前值。

```moonbit
let statement = connection.prepare(
  "UPDATE app.settings SET value=? WHERE id=? IF value=?",
)
let result = statement.execute_conditional(
  [Text("next"), Integer(1), Text("initial")],
  options=@protocol.QueryOptions::new(
    serial_consistency=LocalSerial,
    skip_metadata=true,
  ),
)
if !result.applied {
  ignore(result.page.get(0, "value"))
}
```

普通 CQL 也可通过 `query_conditional` 执行 `INSERT ... IF NOT EXISTS`。
若把没有 `[applied]` 布尔列的普通查询传入这些接口，会返回 `Unexpected`，不虚构条件状态。

Cassandra 5.0.5 的 EXECUTE 在 v5 下，即使请求设置了 `skip_metadata`，也始终为 LWT 返回本次列定义，且不设置 METADATA_CHANGED。
成功通常只含 `[applied]`，失败还可能包含原值；不能把成功时的列定义套在失败结果上。
驱动按每次响应的元数据解析，只有带 METADATA_CHANGED 的普通预处理响应才更新结果元数据 ID 缓存。
QUERY 没有上述服务端特例，因此 `query_conditional` 会清除 `skip_metadata`，保证首次条件查询也能读取本次的返回列。

条件写入可能在客户端超时或取消前已经生效；当前默认不会为这类错误重放写入。
SERIAL / LOCAL_SERIAL 控制条件阶段的一致性，普通 `consistency` 则控制提交阶段的一致性。

`cmd/integration/conditional.mbt` 验证 IF NOT EXISTS 与 IF 条件成功和失败、当前列值、两种串行一致性，以及与普通预处理读取交错时的元数据行为。
