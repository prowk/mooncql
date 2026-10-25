# 节点负载与 Session 总额度

[文档目录](README.md) · [背压](backpressure.md) · [路由](routing.md) · [连接健康](connection-health.md)

本页适用于**0.2.1**。0.2.0 的单连接额度保持其发布时的定义；0.2.1 新增固定的 Session 总额度。

## 配置与计量

通过 `SessionBuilder::new(limits=SessionLimits::new(...))` 设置，默认值如下。每条连接的 `ConnectionBuilder` 额度同时生效，两个层级均须有可用额度才准入。

旧 with_session／SessionConfig 继续只执行原有逐连接在途预算，不自动增加全局 128 个限制；其 Session.budget().limits 为 None，但计数仍聚合当前全部连接。SessionConfig.builder() 保留此行为。直接创建 SessionBuilder 时 enforce_limits 为 true，limits 为 Some；要在转换后的 Builder 启用总额度，可显式把 enforce_limits 设为 true。

| SessionLimits 参数 | 默认值 | 含义 |
| --- | --- | --- |
| `max_in_flight` | 128 | 所有已建立连接实际 RPC 的合计数量 |
| `max_in_flight_bytes` | 67108864 | 合计未压缩请求 envelope 字节 |
| `max_waiting` | 64 | 合计等待者数量 |
| `max_waiting_bytes` | 67108864 | 合计等待字节 |
| `overload_policy` | `Wait` | 有界等待；`Reject` 时额度不足立即失败 |

数量上限为 1–1048576，字节上限至少 9，等待数量为 0–1048576，等待字节可为 0；非法配置在建立 TCP 连接前失败。节点发现、新增节点或重连不会扩大这些固定上限。每个 Session 独立计量，不在不同 Session 之间共享额度。

实际请求按编码体加 9 字节 envelope 头计量，包含等待写锁的已准入请求。压缩不减少计费。业务查询、PREPARE／EXECUTE、BATCH、重试、schema agreement、目录分页、控制连接 REGISTER／系统表读取和空闲心跳都经过同一底层准入。初始 TCP／TLS／认证握手不分配业务 stream，使用原有连接超时和认证交互上限，不计入此 RPC 预算。此预算也不是进程 RSS 上限；接收结果、调用方参数、编码临时对象和运行时仍需额外内存。

Session 选择等待、schema 读取合并、节点准备锁及物理连接等待都使用总等待预算，同时保留各自原有上限。等待之间交接额度，不把同一个等待者重复计入两个阶段。`Session.budget()` 返回当前总数量、字节、等待及配置快照；`Session.resources()` 继续提供连接、任务、stream 和缓存资源汇总。共享预算不会让原有聚合 Metrics 重复计数。

## 节点选择与等待

选择器保留本地 DC、token 副本、远端回退及已尝试节点的原顺序，依次查找健康且具有请求额度的连接，跳过满载候选。在同一优先级内轮转；候选重新有空位后重新参与轮转。不修改一致性级别，也不会绕过 `allow_remote=false`。

所有健康候选满载时进入有界 Session 等待，收到任意连接归还额度的通知后由 FIFO 队首重新选择，避免固定排在某条满载连接上。新请求不得越过等待中的大请求。满载等待受 `queue_timeout_ms` 与操作 Deadline 中较早者约束，阶段为 `WaitingSlot`。没有可选健康节点时继续使用原有 `WaitingConnection` 和总操作 Deadline。取消与期限到达立即移除 FIFO 位置；路由约束使队首没有候选时，后续操作也可能等待，业务侧仍应控制同时创建的任务数。

Session 或连接任一层配置 `Reject` 时，不把满载操作放入队列；没有可选健康节点仍遵守恢复等待语义。总预算返回独立的 `SessionOverloaded(reason)`，原因沿用稳定版的 InFlightLimit、ByteLimit、WaitingQueueFull、WaitingBytesFull 和 RequestTooLarge；单连接继续返回 Overloaded(reason)。这种分离不扩展旧 OverloadReason 的封闭分支。单条请求超过任何在途字节上限时直接失败，不等待一个永远不可能满足的预算。服务器 OVERLOADED 仍是独立的服务端错误。

取消或超时的排队者立即归还等待额度；完整发送后的请求继续占用两层在途额度，直到迟到响应排空或连接关闭。重试的每个实际 RPC 独立计费，旧请求的保留额度不会因开始重试而消失；是否允许重放仍由显式幂等声明和原有故障语义决定。

心跳先检查总额度与 FIFO 等待者，满载或有人排队时跳过本次探测。检查后发生争用造成的本地排队失败也不判定连接失活。发出的心跳按一个 9 字节 OPTIONS 请求计费。

控制目录查询与业务共享同一个 FIFO 和总预算，不额外预留或扩大额度。在 Wait 策略、旧请求持续完成、目录请求大小可放入预算且期限充足时，新业务不能无限越过已排队的刷新；控制请求也不能越过旧业务。Reject 策略明确允许刷新被拒绝，不承诺满载期间成功。本地额度拒绝或尚未发送的排队超时只标记目录 stale，保留健康连接和订阅，按 `backoff_initial_ms` 等待后重试；协议、网络、身份或发送后失败仍触发原有控制连接恢复。排空停止新心跳与恢复工作，关闭后所有持有和等待额度均回收。

## 可运行验证

[只读示例](../cmd/limits/main.mbt)同时发起十二次 `system.local` 读取，每条连接最多一个在途 RPC，Session 合计最多两个；断言观测峰值没有越界，排空后所有额度和后台任务归零。

```sh
moon run cmd/limits
```

使用常规 `CQL_HOST`、`CQL_PORT`、`CQL_USERNAME`、`CQL_PASSWORD` 和 `CQL_COMPRESSION`。`CQL_CONTACT_PORTS` 可覆盖端口为同一主机上的逗号分隔列表，例如三节点测试环境的 `19052,19053,19054`。账号需有读取 `system.local` 的权限。成功输出包含 `PASS Session total budget requests=12`、实际峰值和 `resources=0`，不把峰值或连接数量当作性能收益。

CI 在四种认证与压缩组合及三节点环境运行此示例。确定性 TCP 回归另覆盖满载跳过与恢复轮转、跨三节点数量／字节总上限、持续拒绝、等待取消、超时、迟到响应、控制连接、合并目录读取及心跳占用。
