# 连接健康管理

[文档目录](README.md) · [连接配置](configuration.md)

连接默认在空闲 30000 毫秒后发送 OPTIONS 心跳，等待已协商的 v5 SUPPORTED 响应。心跳使用与普通请求相同的帧、CRC、压缩、stream 关联和额度管理，不执行 CQL。

```moonbit
let config = @client.Config::new(
  heartbeat_interval_ms=30000,
  heartbeat_timeout_ms=5000,
)
```

`heartbeat_interval_ms=0` 关闭心跳；负间隔或非正超时属于配置错误。后台检查间隔不超过一秒。收到正常响应或事件会重置空闲计时；有在途、废弃或排队请求时跳过心跳，业务请求仍受自己的超时约束，废弃请求仍由既有数量与存活期限限制。

心跳没有得到有效 SUPPORTED 响应时以 `HeartbeatFailed` 回收连接。Session 随后按已有退避策略恢复，新请求可以使用替换后的连接，SessionPrepared 可以重新准备。心跳失败不隐式重放业务写入。低层 Connection 关闭后需要调用方重新建立。

心跳预算由 `heartbeat_timeout_ms` 限制，同时仍遵守连接请求的排队和执行期限；不会为每次心跳重新建立 TCP 或 TLS。关闭连接会取消心跳任务，`shutdown` 和 `Session.close` 会等待任务结束。

Metrics 的 RPC 计数包含心跳 OPTIONS，可通过监听器的 opcode=5 区分。资源快照包含心跳任务句柄；停止 Session 后句柄、pending 和字节额度应归零。

该机制用于发现空闲连接的半断开状态，不提供数据库可用性的强保证，也不等待 schema agreement。应用仍应按业务设置 Deadline 和一致性级别。
