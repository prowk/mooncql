# 指标与请求监听

[文档目录](README.md) · [入门教程](getting-started.md)

本文适用于 0.2.0。Config 默认不创建观测对象；传入同一个 Metrics 可汇总一个 Connection 或整个 Session 的连接、请求、资源额度、缓存与压缩帧。Metrics 不创建后台采样任务，也不保存请求历史。

```moonbit
let metrics = @client.Metrics::new()
@client.with_connection(
  config=@client.Config::new(host="127.0.0.1", port=9042, metrics~),
  connection => {
    ignore(connection.query("SELECT release_version FROM system.local"))
  },
)
let snapshot = metrics.snapshot()
println("completed=\{snapshot.requests_succeeded}, inflight=\{snapshot.in_flight}")
```

Metrics::new(listener=callback) 同时启用同步监听。MetricEvent 包括请求开始 / 结束、连接尝试 / 建立 / 失败 / 关闭、节点或控制连接恢复、缓存命中 / 未命中 / 合并 / 淘汰，以及连接等待、准备锁等待和重试退避结束。回调可以抛出 MoonBit Error，驱动会隔离该错误并增加 listener_errors，不让它破坏收发或额度回收。回调在事件发生的任务内执行，应快速返回；驱动不另建无界事件队列。

请求事件只携带 endpoint、opcode、字节数、结果类别、阶段、是否可能已发送及阶段耗时。错误类别保留服务端数字错误码或 TimeoutInfo，不包含原始错误文字。事件不包含 CQL、绑定值、密码、warnings 或 custom payload；默认也不输出日志。应用若需要业务结果中的执行附加信息，可显式使用 [with_info](execution-info.md)。

snapshot 是独立的数值副本，修改它不会改变驱动状态。主要字段如下：

| 范围 | 可观测项 |
| --- | --- |
| 连接 RPC | requests_started / succeeded / failed / cancelled、request_timeouts、queue_ms、execution_ms |
| 资源 | in_flight / in_flight_bytes、waiting / waiting_bytes，以及对应 peak 字段 |
| 连接 | connect_attempts、connections_established / closed、connect_failures / cancellations / timeouts |
| 恢复 | reconnects（业务节点）与 control_reconnects |
| 缓存 | cache_hits / misses / coalesced / evictions |
| 等待 | session_wait_*、prepare_wait_*、retry_wait_* 的次数、耗时、失败、取消和超时 |
| 压缩帧 | sent / received 的帧数、原始 payload 字节、编码 payload 字节和完整 frame 字节 |
| 监听 | listener_errors |

请求统计以一次连接 RPC 为单位，包括 PREPARE、REGISTER、心跳 OPTIONS 等已经调用 request 的操作，握手不计入 RPC 数。服务端 ERROR 计为失败，即使低层 request 正常返回 Reply。Session 重试和 UNPREPARED 恢复会产生多个 RPC；缓存命中或合并等待不虚构额外 RPC。total_timeouts() / total_cancellations() 汇总各阶段计时或取消事件，不是按业务逻辑调用去重的数量。

请求 queue_ms 从进入连接接口计至获得发送锁；execution_ms 从获得锁计至该次调用结束。Session 等可用连接和准备锁等待另有独立字段，并计入总 queue_ms；重试退避单独计入 retry_wait_ms。耗时使用单调时钟，分辨率为毫秒。普通业务连接与可选控制连接共用 Metrics 时，其 RPC 和帧均包含在汇总中。

waiting 同时计入无健康连接、连接准入和准备锁的真实等待额度。SessionPrepared 更换连接及 UNPREPARED 恢复的锁等待也受数量和字节预算约束。请求完整发送后取消，取消计数立即更新，而 in_flight 额度仍保留到迟到响应或有界连接回收；指标不把取消误当成服务端已经撤销执行。关闭后等待相关调用结束，再检查额度归零。

sent_payload_ratio() / received_payload_ratio() 为编码 payload 字节数除以原始 payload 字节数，越小表示压缩后越少；没有帧时返回 1，可用帧数区分空样本。frame 字节包括 v5 帧头与 CRC，比例本身不包含这些固定开销。只统计完整写出或成功解码的帧，握手 envelope、部分写入、无效帧以及 TCP / TLS 自身开销不在这些字节数内。

观测开销可用专用脚本复现。它对同一服务端交错运行加入指标前的提交、当前关闭全部观测、仅计数器、计数器加空监听器四种模式；每条查询校验结果。旧版副本仅创建在忽略的 .tools，原始结果保存在 .artifacts，源码 SHA-256 与工具链一并记录。

```sh
CQL_PORT=19042 CQL_USERNAME=cassandra CQL_PASSWORD=cassandra CQL_COMPRESSION=none \
  python scripts/observability_bench.py --count 20000 --trials 7 --concurrency 32
```

基线提交默认为 2acd8d07a50a206816635e052b74672a8ee29643，仓库需要包含该提交；浅克隆可先获取它。基准使用 native release、复用预处理 SELECT system.local、计时前预热、固定随机种子交错顺序，记录所有轮次。它测量当前环境中的完整数据库往返，不把单次噪声当作性能提升，也不替代完整的性能矩阵。
