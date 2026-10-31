# 响应限制与接收内存

[文档目录](README.md) · [背压](backpressure.md) · [取消](timeouts.md)

本页接口适用于 0.2.1 和 0.2.2。通过 `ResponseLimits::new` 构造不可变限制，在 `with_connection_builder`、`with_serial_connection_builder`、`connect_builder` 或 `with_session_builder` 传入 `response_limits~`。Session 的所有数据槽、重连和控制连接继承该限制；原有 ConnectionBuilder 记录无需添加字段。

| 参数 | 默认值 | 合法范围 |
| --- | --- | --- |
| `max_body_bytes` | 16777216 | 1–2147483647 |
| `max_rows` | 1000000 | 0–1000000 |
| `max_columns` | 65535 | 0–65535 |
| `max_value_nodes` | 1000000 | 1–1000000 |
| `max_depth` | 32 | 1–32 |

未传入限制时，正文沿用 `ConnectionBuilder.max_frame_bytes`，其他维度沿用既有协议上限。显式正文限制与 `max_frame_bytes` 取较小者，作用于解压后的整个响应 envelope 正文，并在读取或重组超长正文之前失败。行数、列数、每页所有单元格共用的 Value 节点数分别检查，嵌套类型和 Value 深度均受约束。预处理参数和结果元数据同样检查列数与类型深度。零行／零列上限可拒绝相应结果；VOID 不受行数限制。

非法限制由构造器在建连前返回带参数名与范围的 Configuration。收到超限响应返回 CodecError 并关闭物理连接，唤醒请求并回收 stream 和发送额度；不尝试跳过半个 ROWS 后继续解码。Session 可按既有规则重建连接；未知结果的写入和 BATCH 不自动重放。控制目录也可能因为过低限制无法刷新，此时保持 stale。

## 观测与所有权

`Connection.receive_memory()` 和 `Session.receive_memory()` 返回物理连接快照，包含 endpoint、pool_slot 和 RPC scope。`reassembling_bytes` 为解码器保存的分片正文与头前缀，`queued_envelope_bytes` 为验证完成但尚未交给读循环的正文，`delivering_body_bytes` 为读循环处理后尚未由请求任务接走的正文逻辑字节。两个 peak 字段分别表示 wire 暂存和交付阶段峰值，不能相加当作同时刻进程峰值。计数还包含成功解码和跳过的废弃响应，以及毫秒精度的累计／最大同步解码时间。

这些是驱动保留的正文逻辑字节，不包含 Writer 预留容量、重复复制、Value 对象、TLS、socket 缓冲或运行时开销。结果交给调用方后，调用方保留的 Page／Row 不再计入交付指标；RSS 仍可能上升。分页不会为慢消费者预取下一页，应用应限制同时使用的 Pager 和保留页数。当前没有会阻塞某条连接排空的接收总预算。

## 废弃响应

完整发送后取消的请求仍保留 stream 与发送额度。迟到响应必须先通过完整帧 CRC、长度和消息边界、v5 方向、已知 stream 及响应 opcode 检查，随后排空并归还额度，不构造 Row／Value，也不更新预处理元数据。废弃正文内部的 ROWS、类型、警告和扩展内容不再进行语义校验；其结果已不会交给调用方。活动请求仍执行正常正文解码和限制。帧损坏、未知 stream、重复响应及未知 opcode 均导致连接失败；废弃正文仍受单正文大小限制。

取消与同步解码之间没有异步切换点：响应先进入交付阶段时，按正常解码处理，后续取消只归还交付所有权；先完成取消标记时走废弃路径。stream 仅在完整消息排空或连接关闭后复用。
