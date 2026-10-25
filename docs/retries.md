# 显式幂等重试

[文档目录](README.md) · [入门教程](getting-started.md)

本文适用于 0.2.0。默认每个业务请求只尝试一次；连接自动恢复不会重放失败的请求。只有调用方明确声明 `idempotent=true` 后，Session.query、Session.request 的 QUERY / EXECUTE 和 SessionPrepared.execute 才启用 RetryPolicy。驱动不分析 CQL，也不根据 SELECT 等前缀推断幂等性。

```moonbit
let result = session.query(
  "SELECT release_version FROM system.local",
  idempotent=true,
  retry=@client.RetryPolicy::new(max_attempts=3, delay_ms=10),
  deadline=@client.Deadline::after(1000),
)
```

`max_attempts` 包含第一次尝试，范围为 1–64；默认 3，设置 1 关闭重试。`delay_ms` 为两次尝试之间的非负等待，默认 10 毫秒。重试会重新选择健康节点，只有一个健康节点时可能仍使用同一节点。所有选择、排队、重新准备、执行和等待共享调用开始时的 Deadline，每次尝试不会重新获得完整超时时间。调用取消会结束当前逻辑操作，不能撤销服务端已经执行的操作。

只有断线 / 底层 I/O 错误、执行或排队超时、本地临时额度不足，以及服务端 OVERLOADED、IS_BOOTSTRAPPING、UNAVAILABLE、READ_TIMEOUT、READ_FAILURE 可以在声明幂等后重试。WRITE_TIMEOUT / WRITE_FAILURE 仅允许 SIMPLE 类型；COUNTER、CAS、BATCH 等写类型不会重试。配置、绑定类型、TLS 验证和协议错误均立即结束。匹配 ID 的 UNPREPARED 仍由 Prepared 单独处理，最多恢复一次，且受同一截止时间约束。

counter、自增、集合追加和条件写入不能据此获得至多一次或恰好一次语义，默认保持单次尝试。调用方必须根据业务效果判断幂等性；例如带不稳定时间戳的写入也可能不满足业务要求。BATCH 无论是否传入 idempotent 都不在自动重试入口内。低层 Connection 与 Prepared 接口保留单次业务执行行为。

启用重试后，失败返回 `RetryExhausted(Array[AttemptFailure])`。每条记录包含尝试序号、选中的 Endpoint（选择前或重试等待失败时为空）、原始 Error 和该次请求是否可能已发送。未达到次数上限的永久错误也用该结构保留已经发生的历史；关闭重试时仍返回原始错误。重试等待用尽总预算时会追加 endpoint 为空的 WaitingRetry / Operation 超时记录，保留此前可能已经发送的事实。收到服务端错误也按已发送处理；该字段不表示服务端已经提交写入。

普通查询在首次异步等待前编码，预处理执行在选择节点前复制绑定值和必要选项；后续尝试不会读取调用方已修改的数组。测试覆盖跨节点重试与参数快照、节点 / 原因历史、次数上限、SIMPLE 与非 SIMPLE 写错误、总截止时间、迟到响应隔离、取消，以及默认 counter / LWT / 集合追加 / BATCH 在响应丢失后不重复发送。

开启执行信息后，成功重试的前次响应保存在 info.previous；最终 RetryExhausted 的 AttemptFailure.execution_info 保存相应响应，error 保留原始错误原因。见[执行信息](execution-info.md)。

## 开发分支的分类退避

在 `ExecutionProfile::new(backoff=RetryBackoff::new(...))` 显式启用。省略 `backoff` 时仍使用 RetryPolicy.delay_ms 的固定延迟；启用时由分类退避替代固定延迟，次数上限、幂等声明和同一 Deadline 均不改变，RetryPolicy 的公开记录字段保持不变。

| 起始延迟参数 | 默认毫秒 | 选择条件 |
| --- | --- | --- |
| `local_ms` | 5 | 本地额度拒绝、尚未发送的排队超时 |
| `overloaded_ms` | 25 | 服务端 OVERLOADED |
| `bootstrapping_ms` | 100 | 服务端 IS_BOOTSTRAPPING |
| `network_ms` | 10 | 可重试的断线、I/O、执行超时或其他既有可重试原因 |
| `read_timeout_ms` | 25 | 服务端 READ_TIMEOUT |

第一次失败后的上界是起始值，之后每次翻倍，并在 `max_delay_ms`（默认 1000）截断。`jitter` 默认 1，表示在零到本次上界之间均匀取样；0 为无抖动，其他合法值形成 `[上界 × (1-jitter), 上界]` 区间，结果向下取整。每个 Session 使用独立熵源，各逻辑操作共享推进的随机序列，不按错误同时发生的时刻重置种子。没有可用平台熵时随机库使用其固定回退种子，不能提供跨进程的去同步保证。

各类别起始值允许为 0，且不得大于正数 max_delay_ms；jitter 须为 0–1，非法值在构造器报出参数名及范围。倍增前检查上界，极值不会发生 Int 溢出。退避期间取消立即结束，Session 关闭会唤醒等待，不等完整延迟。若共享 Deadline 在退避中到期，保留原失败历史并追加 WaitingRetry 超时，不再发送下一 RPC。原生回归固定种子核对抖动分布和重放，实际 TCP 回归核对分类延迟及一个逻辑操作对应三次 RPC 的计数。

SessionPrepared 和 Pager 保存选定的不可变 profile；单次显式 profile 替换继承配置，其没有 backoff 时回到固定延迟。原始 Session.request 使用 Session 默认 profile 的 backoff。实际放大可由 Metrics 的 requests_started／logical_started 和 retry_attempts 结合观察；前者包含被本地拒绝的 RPC 尝试，并非服务器已执行次数。
