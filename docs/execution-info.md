# Tracing、custom payload 与执行信息

[文档目录](README.md) · [入门教程](getting-started.md)

本文适用于 0.2.0。给 QueryOptions 传入 RequestOptions，可为 QUERY / EXECUTE / BATCH 发送 tracing 标志和 custom payload；PREPARE 通过 prepare 的 request_options 参数传入。

```moonbit
let options = @protocol.QueryOptions::new(
  request_options=@protocol.RequestOptions::new(
    tracing=true,
    custom_payload=Map([("application-tag", Some(b"example"))]),
  ),
)
let execution = connection.query_with_info(
  "SELECT release_version FROM system.local",
  options~,
)
let result = execution.value
let trace = execution.info.tracing_id
```

RequestOptions 和 QueryOptions 的快照复制 payload Map。分页创建时、预处理执行等待前和普通查询编码时分别冻结必要选项，后续页面、重新准备及重试不读取调用方已修改的 Map。custom payload 使用 envelope 的 0x04 标志和正文前置 bytes map；请求 tracing 为 0x02 标志，不在请求正文插入 tracing UUID。扩展字节计入消息长度与在途预算，仍按 v5 外层帧和 LZ4 规则发送。编码按 key 排序，语义相同的 payload 不因 Map 插入顺序影响准备缓存键。

需要执行信息时使用以下高层接口，返回 `Execution[T]`，其中 value 为业务结果、info 为 ExecutionInfo：

| 对象 | 接口 | value |
| --- | --- | --- |
| Connection / Session | query_with_info | ResultSet |
| Connection / Session | prepare_with_info | Prepared / SessionPrepared |
| Prepared / SessionPrepared | execute_with_info | ResultSet |
| Connection | batch_with_info | Unit |
| Pager（普通 / 预处理） | next_with_info | Page，读完时整个返回值为 None |

info 包含实际 coordinator、attempt_count、warnings、tracing_id、custom_payload、previous 和 cached。previous 按响应发生顺序保存前次执行、自动 PREPARE 或恢复响应；其中的前次失败记录也可能带有 previous，可递归查看。最终响应的字段留在当前 info，前次响应不会被覆盖。attempt_count 统计业务 QUERY / EXECUTE 的尝试，UNPREPARED 后再次 EXECUTE 计入，恢复中的 PREPARE 响应在 previous 中单独保留。

准备缓存命中时 cached=true、attempt_count=0，返回该语句最近一次实际 PREPARE 的响应信息，不声称本次又发送了网络请求。并发合并准备可共享一次请求的响应。trace 标志不改变缓存键；CQL、keyspace 和 custom payload 内容共同区分准备内容。修改返回的准备信息不会改变缓存内部信息。

低层 Reply 保留原有 warnings / tracing_id / custom_payload，并新增 coordinator、attempt_count、previous；execution_info() 提供统一视图。Session 重试最终失败时，RetryExhausted 中每条 AttemptFailure 的 execution_info 保存该次已收到响应的附加字段，error 仍为原始错误原因。

with_info 接口遇到已收到响应的服务端错误会抛出 `ExecutionError(cause, info)`，保留原错误及响应信息。恢复阶段随后遇到超时或绑定类型变化时，也保留此前已收到的响应。完全没有收到响应的传输失败和配置错误可直接返回原始错误。原有 query / execute / batch / next 等简洁接口继续返回原结果及原有错误类型；选择 with_info 接口即可检查这些附加信息。

默认 Cassandra QueryHandler 忽略请求 custom payload，不保证回显，空返回属于正常行为。不要依靠它传递业务写入数据。v5 规范明确保证 QUERY / PREPARE / EXECUTE 的 tracing；本仓库实际测试的 Cassandra 5.0.5 也为 BATCH 返回可查询的 trace UUID，但不据此扩展到其他服务端版本。tracing 写入 system_traces 有异步延迟，可用返回的 UUID 查询 system_traces.sessions / events，短时间未出现时应稍后读取。

回归包括独立请求字节、选项快照、普通 / 预处理分页、成功和耗尽的跨节点重试、UNPREPARED 成功及重新准备失败、缓存命中与信息隔离。真实集成在 Cassandra 5.0.5 上核对 QUERY、PREPARE、EXECUTE、BATCH 及每页的 trace，并实际查询所有返回 UUID；认证 / 压缩矩阵沿用 cmd/integration 和 CI。
