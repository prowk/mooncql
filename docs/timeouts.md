# 超时、截止时间与取消

[文档目录](README.md) · [入门教程](getting-started.md)

本文适用于 0.2.0。

| 配置 | 覆盖范围 |
| --- | --- |
| `connect_timeout_ms` | DNS、TCP 连接、OPTIONS、STARTUP 和认证的整个连接过程 |
| `queue_timeout_ms` | 一次请求等待在途名额与写锁的合计时间 |
| `timeout_ms` | 获得写锁后，发送消息至收到响应的时间 |
| `operation_timeout_ms` | 一次高层调用的总预算，包括等待准备锁、EXECUTE、UNPREPARED 后重新 PREPARE 与再次 EXECUTE |

后三个可选配置未指定时继承 `timeout_ms`，默认均为 10000 毫秒。所有时间使用运行时单调时钟。

`Deadline::after(milliseconds)` 创建截止时间。`query`、`prepare`、`Prepared.execute`、条件写入、`batch`、`request`、`run`、`Pager.next` 和 `connect` 接受 `deadline~`。共享同一个 Deadline 可将多次调用放在同一个总预算内；内部重新准备不会延长它。分页默认每次 `next` 单独计时；需要限制整次遍历时由调用方传入同一个截止时间。

`TimedOut(info)` 包含 `scope`、`phase` 和 `may_have_been_sent`。scope 是 Connection、Queue、Execution 或 Operation。phase 区分连接、等待名额、等待写锁、发送、等待响应和等待准备锁。`may_have_been_sent` 对应用请求而言，在第一次网络写入前为 false；开始写入后保守地为 true。它不代表服务端是否执行成功。Connecting 阶段尚未发送应用查询。

未发送的请求退出时归还资源。完整发送后超时或取消的请求保留 stream 和在途额度，读任务继续吸收迟到响应；达到废弃数量或存活时间限制会关闭连接。部分发送、非法响应与断连会关闭连接。驱动不会因为这些错误重放写入，也不能通过取消撤销服务端执行。

`with_connection` 与 `with_serial_connection` 使用相同计时实现；后者仅将最大在途数量设为 1。直接调用 `connect(group, config~)` 时，调用方任务组管理读任务及废弃请求回收任务。退出作用域会取消并等待后台任务；如需提前停止可调用 `close`。

回归位于 `client/deadline_test.mbt` 与 `client/cancellation_test.mbt`：握手停顿、串行与多路复用相同边界、排队超时、响应超时、写锁总截止时间、UNPREPARED 共用总截止时间、过期预算不发送，以及各阶段取消后的资源归还。
