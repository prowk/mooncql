# 从 0.1 升级到 0.2

[文档目录](README.md) · [入门教程](getting-started.md)

```sh
moon add --upgrade prowk/mooncql@0.2.0
```

0.2 新增 Session、TLS、节点发现与路由、显式幂等重试、执行信息、指标、Row 类型化读取和可恢复分页游标。已有 Connection、Prepared 和基础分页接口继续保留。

## 生命周期

需要自动恢复时，从 `with_connection` 改用 `with_session`，并通过 Session.prepare 创建跨连接代次可用的语句。Connection.prepare 返回的 Prepared 仍绑定原连接。不要把 Prepared ID 或 bind_batch 结果跨物理连接使用。

## 超时和取消

0.1 的取消或超时会关闭连接。0.2 对完整发送的请求保留 stream 和额度，吸收迟到响应；部分发送或协议状态损坏仍关闭连接。废弃数量或存活期限超限也会回收连接。取消不表示服务端撤销执行。

新的 TimedOut 包含作用域、请求阶段及可能发送标志。一次高层操作中的重新准备和重试共享 Deadline。匹配 DriverError 的穷尽分支需要处理新增错误，包括空闲健康探测的 HeartbeatFailed。

## 默认行为

写入仍默认单次尝试；只有明确声明幂等后才启用可重试的错误类型。空闲连接默认每 30 秒心跳，可通过 heartbeat_interval_ms=0 关闭。max_in_flight 仍默认 128；准备缓存默认 64，现可配置。

读取参数元数据和 Row 列定义得到隔离快照，修改返回的嵌套 tuple 或 UDT 不会改变内部状态。默认写时间戳现在接受 Cassandra 5.0.5 支持的负值，Int64 最小值仍保留。

## 当前开发分支（尚未发布）

新增 Session 批处理、可插拔认证与优雅排空，参见[开发接口](development-api.md)。使用 `Config::new` 的原有调用保持兼容；手工构造完整 Config 字面量时，须补齐新字段，推荐改为 `{ ..Config::new(), ... }`。穷尽匹配 DriverError／TimeoutPhase 时须增加 `Draining`／`WaitingDrain` 分支。

认证拒绝现在返回脱敏的 `Authentication`，不再把服务端可能回显凭据的原始 ServerError 直接暴露；业务查询的 ServerError 不受此改变影响。默认作用域关闭仍立即取消，只有显式调用 drain 才等待；BATCH 无论低层还是新 Session 接口均不自动重放。
