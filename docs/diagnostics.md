# 运维诊断与 Prometheus

[文档目录](README.md) · [原有指标](metrics.md) · [连接健康](connection-health.md) · [超时](timeouts.md)

本页的逻辑调用事件、RPC 分类和导出示例适用于 **0.2.1**。0.2.0 只有[原有 RPC 与资源指标](metrics.md)。默认不创建 Metrics；观测和导出均需显式启用。

## 指标口径

| 维度 | 口径 |
| --- | --- |
| Session 逻辑调用 | 接受后的 query、prepare、execute、batch、request 和三个 schema API，各计一次；普通接口与 with_info 不重复计数 |
| 节点实际 RPC 尝试 | 进入物理 Connection.request 的调用，按 endpoint、data／control／heartbeat 分开，包括 PREPARE、EXECUTE、QUERY、BATCH、REGISTER、OPTIONS；发送前本地拒绝也记录 |
| Session 重试尝试 | 第一次以后的尝试成功选中连接、即将调用实际动作时计数；退避被取消或选节点失败不虚构节点重试 |
| UNPREPARED 恢复 | 额外 PREPARE／EXECUTE 都是 RPC，错误码另分类；不计为显式 Session 重试 |
| 资源 | 从 Session／池当前快照读取，取消后的 abandoned、pending 和额度保留到实际排空或回收 |

逻辑调用可能跨多个节点重试，因此按 Session 计数；各次 RPC 和重试尝试按实际节点计数。分页每次取页产生自己的逻辑调用，整个遍历不再额外计一次。编码校验或已关闭／排空状态在接受前拒绝的调用不计入逻辑开始。schema agreement API 正常返回 Unknown／Disagreed 报告仍是一次成功返回，收敛状态应读取报告。

RPC 尝试计数不表示服务端一定收到请求；`mooncql_rpc_possible_sent_total` 另按 may_have_been_sent 统计可能已经发送的调用，仍不等同于 Cassandra 已执行成功。

为兼容 0.2.0，`MetricEvent`、`RequestEvent`、`MetricsSnapshot` 和 `RequestOutcome` 保留原字段及分支。使用 `Metrics::with_diagnostics(callback, listener?)` 订阅独立的 `DiagnosticEvent`：`OperationStarted`、`OperationFinished`、`RetryStarted` 对应逻辑操作及重试，`RpcFinished(scope, event, session_budget)` 附带 RPC 来源及是否由 Session 总额度拒绝。OperationEvent 也有 session_budget 标记；只在 outcome 为 LocalOverload 时用于区分额度范围。`Legacy(event)` 同时转发原有事件，但导出器不能把它与 RpcFinished 重复计为两次 RPC。`ConnectionFailure(endpoint, outcome, authentication)` 保留旧结果分类并另标识认证拒绝；旧监听器仍收到不含原始认证文本的 OtherFailure。

`RpcTimeline(RequestTimeline)` 提供同一 Metrics 内唯一的 request_id、单调毫秒时钟的排队、首次 socket 写入尝试和完成时刻。发送前拒绝的 sending_at_ms 为 None；它不是服务端收到或提交时间。时间线只通过显式监听器投递，不在驱动内保存历史；默认无 Metrics 时不采集。负载程序的计划到达与应用调度时间另以单调纳秒采集，见[性能基准](performance.md)。

驱动生成的请求指标、时间线和游标 Debug 不携带 CQL、绑定值、payload 或认证 token。业务 ServerError.message、服务端 warnings／custom payload 属于原始服务端数据，可能回显敏感文本；应用自行打印它们，或打印 Value／低层 Request 的 Debug，必须自行脱敏。默认指标导出器不将这些内容写入日志或标签，认证错误另有强制脱敏。错误原因可由 ExecutionError、RetryExhausted 历史与 SchemaMetadataError 包装保留；取消不会转换成可重试业务失败。

只有驱动空闲探测使用 heartbeat；手动发送 OPTIONS 仍属于普通 data。`metrics.operations_snapshot()` 返回独立的 `OperationMetricsSnapshot`，其中 logical_* 是逻辑开始／成功／失败／取消和耗时，retry_attempts 是上述重试尝试。`metrics.snapshot()` 的原有 requests_*、total_timeouts() 和 total_cancellations() 保持旧口径，不把逻辑计数叠加进去。只使用原监听器的代码无须增加匹配分支或记录字段。

每个 Session 使用自己的 Metrics，避免混合不同 Session。两个监听器都同步执行，需快速返回且不得阻塞；驱动隔离监听器错误并累计到同一个 listener_errors。没有异步投递队列。原生回归验证在请求开始／结束回调内关闭连接、两种监听器抛错、退出后回调停止；一个逻辑请求不会因此重复完成。以 16 个事件各忙等 3 ms 的本地检查观察到约 49 ms 累计阻塞，说明慢监听器的成本直接落在请求任务上；这是约束演示，不是生产开销结论。

## Prometheus 文本示例

可运行的 [cmd/prometheus](../cmd/prometheus/main.mbt) 对专用 Cassandra 准备一个只读语句、执行三次、观察至少一次心跳，然后排空并输出文本：

```sh
CQL_METRICS_FILE=mooncql.prom moon run cmd/prometheus
```

沿用 `CQL_HOST`、`CQL_PORT`、`CQL_USERNAME`、`CQL_PASSWORD` 和 `CQL_COMPRESSION`。开启 `CQL_TLS=1` 后使用系统信任根；`CQL_TLS_CA` 与 `CQL_TLS_NAME` 可覆盖 CA 文件和服务端名称。示例不需要 DDL 权限。它为短时验收把心跳间隔设为 200 毫秒；正式应用应使用自己的健康配置。

文本生成器见 [exporter.mbt](../cmd/prometheus/exporter.mbt)。应用可复用其收集与渲染代码，在自有 HTTP 生命周期中返回 `text/plain; version=0.0.4; charset=utf-8`，或交给 textfile collector；本示例不创建 HTTP 服务。更新 textfile 时由部署脚本写临时文件后原子替换，避免采集到半份内容。一次性示例的计数只覆盖本进程运行期间，长期采集应保持同一个 Meter 与 Metrics。

Windows PowerShell 先执行 `$env:CQL_METRICS_FILE = 'mooncql.prom'`，再运行同一入口。不设置文件路径时输出到 stdout；直接写文件可避免首次编译的工具输出混进采集文本。查询失败时仍在排空后输出诊断文本，然后以失败状态退出。

| 指标 | 含义 |
| --- | --- |
| mooncql_logical_started_total／logical_total | 接受的逻辑开始、按 operation／outcome 分类的完成 |
| mooncql_rpc_total | 按 node／scope／opcode／outcome 分类的实际完成 RPC |
| mooncql_retry_attempts_total | 按节点分类的实际重试动作开始 |
| mooncql_connections_total／connection_failures_total | 连接尝试、建立、失败、关闭和认证／TLS 等失败分类 |
| mooncql_overloads_total | 固定十种过载原因，logical 与 rpc 分开，不应相加当成去重数量 |
| mooncql_*_seconds | 逻辑调用、RPC 排队／执行及连接／准备／退避等待的累计直方图 |
| mooncql_node_* | 当前数据池健康连接、恢复握手、pending、abandoned、stream 空间、额度、等待和准备缓存 |
| mooncql_session_* | Session 总额度、全部连接资源和后台任务；包含独立控制连接 |

RPC 排队从进入连接接口计到取得写锁，执行从取得写锁计到调用结束；Session 选节点、准备锁和重试退避另有 wait 直方图。不要把重叠的分布直接相加。桶界为 0／1／5／10／25／50／100／250／500／1000／5000 毫秒和 +Inf，输出单位为秒，时间分辨率为毫秒；P99 可由 Prometheus 的 `histogram_quantile` 计算。

## 标签与资源上限

示例固定 `session="main"`；实际应用应使用固定、有限的 Session 标识。节点标签最多保留 32 个 endpoint，后续节点及超过 256 长度的标识汇总到固定 `other`；上限可在 Meter 构造时设为 1–256。保留旧节点计数，避免成员反复替换导致标签增长；overflow_events_total 表示被汇总的观测事件。节点地址按规范转义，未知 opcode 归为 other，服务端错误仅区分 UNPREPARED 与普通 server_error。

其他维度固定为三个 RPC 来源、七类 opcode、十三类结果、八类逻辑操作、十类过载和三个等待阶段。每个节点只有固定数组和直方图，不保存请求历史或原始样本；默认上限下最多 33 组节点标签。CQL、绑定值、密码、认证 token、warnings 和 custom payload 不进入默认标签或文本。

available_streams 只表示健康数据连接未占用的协议 ID，仍受连接和 Session 请求／字节额度约束。节点级资源只覆盖数据池，Session 资源包含控制连接。取消事件立即完成，但 pending／abandoned 和 in_flight 可以暂时非零，应等待迟到响应或有界回收后再判断泄漏。

## 排错路径

| 现象 | 检查顺序 |
| --- | --- |
| TLS 失败 | 检查 connection_failures 的 tls 分类、`last_error` 的 TlsFailure；核对 TLS 端口、CA 链、server_name／SAN、有效期和客户端身份，见 [TLS](tls.md) |
| 认证拒绝 | 检查 authentication 分类、AuthProvider 和账户权限；认证错误已脱敏，先核对凭据来源与认证器，不输出 token |
| 全部节点不可用 | 检查 pools 的 Ready／Backoff、attempts 和 last_error、控制连接 stale、地址映射及 local_dc；禁止远端回退时没有本地候选会等待到 Deadline |
| 超时 | 按 TimeoutInfo.phase／scope 和 may_have_been_sent 区分排队、建连、准备、发送与响应等待；结合对应直方图，未知写入结果由业务处理，见 [超时](timeouts.md) |
| UNPREPARED | 检查节点是否重连／替换、缓存容量及错误 ID；驱动只对匹配 ID 的准备恢复一次，不跨连接复用；持续失败核对 schema 与 keyspace，见 [预处理缓存](prepared-cache.md) |
| 过载 | 区分连接额度、Session 总额度、等待数量／字节和单请求过大；增大连接池不会扩大总额度，见 [总额度](session-limits.md) |

## 独立验收

```sh
python -m pip install -r scripts/requirements-metrics.txt
python scripts/prometheus_acceptance.py
```

固定 `prometheus-client==0.21.1` 的独立解析器检查系列唯一性、允许的标签、有限数值、累计桶、+Inf 与 count 一致性、实际 4 次逻辑调用／4 次 data RPC／至少一次心跳，以及关闭后的任务和额度归零。报告和原始文本保存在忽略的 `.artifacts/prometheus-*`，CI 在认证／压缩四组合归档。另有确定性测试检查重试、取消、控制连接分类、标签上限和错误文本转义。格式依据 [Prometheus 文本规范](https://prometheus.io/docs/instrumenting/exposition_formats/)。
