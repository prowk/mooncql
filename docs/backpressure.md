# 背压与过载

[文档目录](README.md) · [入门教程](getting-started.md)

本文适用于 0.2.1 和 0.2.2。

0.2.1 另有[跨连接的 Session 总额度与满载节点选择](session-limits.md)，需同时满足总预算和本页的单连接预算；该增强通过 Builder 显式启用，原入口保留逐连接预算。

| 配置 | 默认值 | 含义 |
| --- | --- | --- |
| `max_in_flight` | 128 | 已取得发送额度的请求数上限 |
| `max_in_flight_bytes` | 67108864 | 在途请求的未压缩 envelope 字节预算 |
| `max_waiting` | 64 | 等待在途额度的请求数上限，可设为 0 |
| `max_waiting_bytes` | 67108864 | 等待请求的已编码 envelope 字节预算，可设为 0 |
| `overload_policy` | Wait | Wait 在有界队列中等待，Reject 在额度不足时立即失败 |
| `throw_on_overload` | false | true 时 STARTUP 发送 `THROW_ON_OVERLOAD=1` |

字节额度按请求体长度加 9 字节 envelope 头计算；压缩前计量，避免高压缩比消息绕过预算。等待写锁的已准入请求也占用在途额度。单条请求超过在途字节预算，返回 `Overloaded(RequestTooLarge)`，不会无限等待。

`Overloaded` 是本地准入错误，原因区分 InFlightLimit、ByteLimit、WaitingQueueFull、WaitingBytesFull 和 RequestTooLarge。服务端返回的 OVERLOADED 保持为 `Server(error)`，协议错误码为 0x1001。二者均不触发普通写入重放。

每条已编码请求在第一次异步等待前登记数量与字节，超过队列上限会立即返回错误。等待中的编码消息总量不超过 `max_waiting_bytes`，已准入消息总量不超过 `max_in_flight_bytes`；帧包装只在准入后执行，每次生成一个至多 131071 字节的载荷。这里的预算表示逻辑请求字节，不表示进程 RSS 上限：调用方的绑定值、编码中的临时复制、接收结果、TLS 和运行时开销需要额外内存。应用仍应限制同时创建的业务任务和输入大小。

响应到达后归还额度。取消等待中的请求也立即归还；完整发送后取消的请求继续占用额度，直到迟到响应被吸收或连接关闭，避免过早复用 stream。断连会唤醒所有排队请求，收尾后计数归零。排队遵守 queue_timeout_ms 和总截止时间。0.2.1 的额度队列遵守 FIFO：旧的大请求无法放入剩余额度时，新小请求也进入队列，不得无限越过。取消或期限到达会立即移除队列位置；准备锁与 schema 合并等待不占据发送队列位置。

`Connection.scheduling()` 和 `Session.scheduling()` 返回排队位置数量、额度通知广播数及等待任务实际唤醒数。Session 各物理连接共用计数；不含 socket 和准备锁等待。FIFO 可能造成队首阻塞：某条连接或路由候选不可用时，后来请求等待它恢复或退出，受既有 Deadline 约束。该规则优先保障有足够期限的旧请求；并不提高配置的数量或字节预算。

`waiting_count`、`waiting_bytes`、`in_flight_count`、`in_flight_bytes` 可观察当前额度。模拟服务端回归覆盖持续背压下重复拒绝、数量和字节拒绝、取消/超时/EOF 归还、过大请求、启动选项字节，以及 OVERLOADED 后仍可使用连接且原写入仅发送一次。真实 Cassandra 集成启用 THROW_ON_OVERLOAD，并覆盖认证与压缩四种组合。

SessionPrepared 的节点准备锁与 UNPREPARED 恢复锁在发生真实争用时同样登记等待数量和编码字节预算；超时、取消或恢复完成会归还。锁的计时器收尾仍由已取得 / 已排队标记保护，避免取得锁后取消造成额度或锁泄漏。
