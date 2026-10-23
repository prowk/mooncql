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

`SessionConfig` 增加默认关闭的 schema agreement 配置；`ExecutionInfo` 增加可选的 `schema_agreement` 报告。常规构造器调用及读取既有字段的代码无需修改；手写完整记录字面量时补上新字段。开启等待后，DDL 成功与等待超时仍分别表示，详见 [schema agreement](schema-agreement.md)。

新增按需 `Session.schema_metadata`、`SchemaOptions` 和隔离的 `SchemaSnapshot`，不会自动读取整份目录。穷尽匹配 `TimeoutPhase` 时须增加 `WaitingSchema`；读取错误为 `SchemaMetadataError(stage, cause)`，详见 [Schema 元数据](schema-metadata.md)。

`SessionConfig` 增加可选的 `execution_profile`，省略时保留既有查询默认值。新增的 [ExecutionProfile](execution-profiles.md) 在准备和 Pager 创建时保存选定配置，每次调用仍需显式声明幂等；单次 `options` 替换整份查询选项。手工构造完整 SessionConfig 记录时须补上字段，穷尽匹配 TimeoutPhase 时须增加 `WaitingPage`。游标格式保持兼容；超时和重试预算不写入游标。

开发分支的 Session 新增 `limits` 字段及固定总预算，默认 128 个 RPC／64 MiB 在途和 64 个等待者／64 MiB 等待字节；多个节点及控制连接合计受限，原单连接限制也继续生效。穷尽匹配 OverloadReason 时须增加五个 `Session*` 原因；满载时可能在 Session 选择阶段等待，相关观测归入 Session 等待，参见[总额度](session-limits.md)。低层独立 Connection 不自动加入其他 Session 的预算。

`SessionConfig` 增加 `connections_per_node`，默认 1，可配置 1–8；手写完整记录字面量时须补齐。多连接下 `NodeStatus.generation` 是该节点累计接受的连接代次，初次建池也会增长；按槽诊断使用 `Session.pools()`，参见[连接池](pooling.md)。已有构造器调用及默认单连接的行为保持兼容。

开发分支的 `MetricEvent` 新增 OperationStarted／OperationFinished／RetryStarted，`RequestOutcome` 新增 AuthenticationError；穷尽匹配时补齐这些分支。手写 RequestEvent 须增加 `scope: RpcScope`，手写完整 MetricsSnapshot 须补上 logical_* 和 retry_attempts。原有请求、超时和取消总数保持 RPC／阶段口径，逻辑调用数独立读取；详见[运维诊断](diagnostics.md)。
