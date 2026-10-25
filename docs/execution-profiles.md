# 请求执行配置

[文档目录](README.md) · [分页](paging.md) · [重试](retries.md) · [超时与取消](timeouts.md)

本页适用于**0.2.1**。已发布的 0.2.0 不包含 `ExecutionProfile`。可复用的请求配置参考 [Java Driver execution profiles](https://apache.github.io/cassandra-java-driver/4.19.0/core/configuration/)，此处直接传递不可变对象，无配置文件、名称注册或热更新。

## 创建和选择

`ExecutionProfile::new` 接受以下参数。构造后无法修改内部状态；`options()` 返回独立的 `QueryOptions`，可用于构造一次调用的选项。

| 参数 | 默认值 | 作用 |
| --- | --- | --- |
| `consistency` | `LocalOne` | 查询和 EXECUTE 的一致性 |
| `page_size` | 未指定 | 普通查询保持服务端行为；Pager 未指定时使用 1000 |
| `serial_consistency` | 未指定 | 只接受 `Serial`／`LocalSerial` |
| `timeout_ms` | 未指定 | 每次逻辑操作的预算，未指定时沿用连接 `operation_timeout_ms` |
| `traversal_timeout_ms` | 未指定 | Pager 整次遍历预算，未指定时无额外遍历上限 |
| `retry` | `RetryPolicy::new()` | 最多三次、延迟 10ms；仍需调用方显式声明幂等 |

`SessionBuilder::new(execution_profile=...)` 设置 Session 的默认配置。`Session.query_with_profile`／`query_with_profile_info`、`prepare_with_profile`／`prepare_with_profile_info` 和 `pages_with_options` 可用 `profile=...` 选择另一组配置。准备得到的 `SessionPrepared` 保存当时选定的配置，其 `execute_with_profile`／`execute_with_profile_info`、`execute_conditional_with_profile` 和 `pages_with_options` 可以再显式选择另一组。

优先级如下，均在操作或 Pager 创建时确定：

1. 单次调用的 `profile` 替换默认配置整个对象；省略时，Session 使用默认值，SessionPrepared 使用准备时保存的对象。不同配置对象之间不逐字段继承。
2. 单次 `options` 替换所选配置的整份查询选项。它自身的 `QueryOptions::new()` 默认值也参与替换。只想补充 keyspace、timestamp、tracing 等选项时，使用 `{ ..profile.options(), ... }` 保留原一致性和页大小。
3. 单次 `retry` 替换配置里的策略；单次 `deadline` 替换该次操作的 `timeout_ms`。它们不改变选定的一致性和查询参数。

幂等性不属于配置。普通查询、执行和 Pager 仍默认 `idempotent=false`，即使所选配置允许多次尝试也不会自动重放。需要重试的 Pager 必须在创建时显式传入 `idempotent=true`；每页都继承同一策略。未知结果的写入与 BATCH 的原有语义不变，BATCH 没有自动套用 Session 查询配置。

没有使用配置的现有调用保留原默认值和参数；Connection／Prepared 仍是绑定物理连接的低层接口，查询不自动获取 Session 配置。PREPARE 使用所选超时；一致性和页大小在后续 EXECUTE 中生效。重新准备、匹配 ID 的 UNPREPARED 恢复及普通重试均共享本次操作的绝对 Deadline。

配置超时是整次逻辑操作的上限。连接自身的排队、请求执行及连接建立上限仍分别生效；较长的配置超时或显式 Deadline 不会延长这些独立上限。

## 分页预算和恢复

Pager 在创建时冻结查询选项、参数、幂等声明和重试策略，每次取页使用新的单页操作预算。`Pager.next(deadline=...)` 或 `next_with_info(deadline=...)` 可显式覆盖这一次取页的预算。

`traversal_timeout_ms` 从第一次取页开始计时，包含重试、调用方处理每页的时间和两页之间的等待。`pages_with_options(traversal_deadline=...)` 可在创建时指定整次遍历的绝对期限；它优先于配置中的相对遍历预算，Connection 和 Prepared 的低层 Pager 也支持它。最终取页期限始终是单页与遍历两者中较早的一个，给下一页更长的 Deadline 不能延长已经开始的遍历。

遍历预算在页与页之间用尽时，下一次取页返回独立的 `OperationTimedOut(WaitingPage, info)`，`may_have_been_sent=false`；在请求过程中用尽则保留原 `TimedOut` 和真实请求阶段。新阶段属于 OperationStage，不扩展稳定版 TimeoutPhase 的封闭分支。显式传入已经过期的单页 Deadline 仍是原 TimedOut／WaitingSlot。预算不强制中断调用方正在执行的行处理回调。失败和取消均不推进游标，已经返回的页仍归调用方所有。

恢复游标时比较已解析配置生成的查询语义，包括一致性、页大小、串行一致性、keyspace、绑定值等。改变这些设置会在发请求前返回 `Configuration`。超时、重试策略和幂等声明可以重新选择；恢复会开始新的遍历预算，游标不保存进程单调时钟的绝对期限。游标可能包含 CQL 和绑定值，不应写入普通日志或接受未受信任的外部游标。

## 可运行示例

[完整示例](../cmd/profiles/main.mbt)在专用 **mooncql_profiles** keyspace 中写入五行，使用默认配置恢复普通查询游标，再通过另一个配置准备和读取三页。它会删除 `items` 表中 `device=42` 的测试分区，需要 DDL 和读写权限，只能连接测试实例。

```sh
moon run cmd/profiles
```

连接使用 `CQL_HOST`、`CQL_PORT`、`CQL_USERNAME`、`CQL_PASSWORD` 和 `CQL_COMPRESSION`。成功输出 `PASS execution profiles rows=5 prepared_pages=3 resources=0`。CI 编译并在四种认证与压缩组合中运行此示例；确定性协议回归另验证每页重试、单次覆盖、超时与迟到响应、游标语义绑定以及默认不重放。
