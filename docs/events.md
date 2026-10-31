# REGISTER 与服务端事件

[文档目录](README.md) · [入门教程](getting-started.md)

本文适用于 0.2.1 和 0.2.2。`connection.register([TopologyChange, StatusChange, SchemaChange])` 等待 REGISTER 对应的 READY，随后用 `connection.next_event()` 异步读取 ServerEvent。事件也可能在 READY 之前到达，接收器会保存到同一有界队列中。

```moonbit
connection.register([SchemaChange])
let event = connection.next_event()
match event {
  Schema(change, target) => println("schema changed")
  _ => ()
}
```

ServerEvent 包含 Topology / Status / Schema 三个分支。拓扑变化区分 NewNode、RemovedNode、MovedNode；状态变化区分 Up、Down。InetEndpoint 保留原始 IPv4 四字节或 IPv6 十六字节地址及端口。Schema 区分 Created、Updated、Dropped，SchemaTarget 明确区分 Keyspace、Table、Type、Function、Aggregate；函数和聚合保留有序的参数类型列表以区分重载。

只有 opcode=EVENT 且 stream=-1 的合法消息进入事件路径。普通消息使用负 stream、EVENT 占用业务 stream、未知事件类型、非法地址及截断消息会使连接明确失败，全部等待者结束。事件不会占用业务请求名额，与乱序普通响应交错也不会改变其关联。

Config.event_capacity 默认 256，范围为 1–65536。慢消费者不会阻塞收发任务；满载时丢弃新事件并增加 dropped_event_count。事件队列不提供可靠消息日志：调用方遇到丢失、重连或怀疑元数据过期时，应重新获取完整系统表快照。事件关闭后，正在等待的 next_event 会失败并结束。REGISTER 作用于具体 Connection，独立重连后的连接需要重新订阅；Session 可通过 [DiscoveryConfig](topology.md) 启用自动控制连接，恢复订阅并刷新完整快照。

固定参考 Event.java 包含 MOVED_NODE，协议规范的简写段落仅列出 NEW_NODE / REMOVED_NODE，驱动以 Cassandra 5.0.5 固定实现补齐该值。[独立字节样例](../fixtures/v5-events.json) 由 Python 标准库生成，覆盖全部变化、五种 schema 对象及两种 IP 宽度。回归还覆盖所有截断位置、非法字段、交错乱序、关闭等待者，以及 1000 个事件突发时查询仍能完成。真实集成入口验证 REGISTER 和表 CREATED / UPDATED / DROPPED 事件。
