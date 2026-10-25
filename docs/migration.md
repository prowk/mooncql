# 从 0.1 升级到 0.2

[文档目录](README.md) · [入门教程](getting-started.md)

```sh
moon add --upgrade prowk/mooncql@0.2.1
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

## 从 0.2.0 升级到 0.2.1

稳定版公开声明相对 0.2.0 保持不变：完整 Config／SessionConfig／ExecutionInfo／RequestEvent／MetricsSnapshot 记录仍可构造，DriverError／TimeoutPhase／OverloadReason／RequestOutcome／MetricEvent 的穷尽匹配保持有效，原函数参数列表也不增加可选参数。扩展能力使用独立新类型和函数名；源码检查同时禁止修改或删除旧声明，不把更新差异合同当作放行破坏性改动。

原 Config／SessionConfig 与 with_connection／with_session 继续保留。动态认证、固定 Session 总预算、每节点多连接、默认执行配置和 DDL 等待使用 ConnectionBuilder／SessionBuilder，配合 connect_builder、with_connection_builder、with_serial_connection_builder 和 with_session_builder。Config.builder() 转换连接值；SessionConfig.builder() 保留旧的逐连接预算语义，Session.budget().limits 为 None。直接创建 SessionBuilder::new() 默认启用固定总预算，limits 为 Some；也可显式调整 enforce_limits。旧入口不会自动从多个逐连接预算变成总计 128 个 RPC 的新限制。

新增 Session 批处理、可插拔认证与优雅排空，参见[批处理与生命周期](development-api.md)。排空拒绝是独立的 Draining 错误。总额度错误是独立的 SessionOverloaded(reason)，单连接仍返回 Overloaded(reason)，原因使用已有 OverloadReason。目录锁等待和两页间遍历预算超时是 OperationTimedOut(stage, info)，阶段属于新的 OperationStage；原 TimedOut 和 TimeoutPhase 仍表示原有请求等待阶段。排空到期仍返回 DrainOutcome，不能据此推断业务成功或服务端撤销。

认证拒绝现在返回脱敏的 Authentication，不把服务端可能回显凭据的认证原文直接暴露；业务查询的 ServerError 不受此改变影响。默认作用域关闭仍立即取消，只有显式调用 drain 才等待；BATCH 无论低层还是新 Session 接口均不自动重放。认证回调每个连接独立创建，重连和额外池槽不会复用上一会话。

DDL 等待报告由 query_with_schema_info 返回 SchemaExecution.schema_agreement，原信息仍在 info。旧 query_with_info 返回原 Execution；在 Builder 显式启用等待时仍执行等待，但需要报告的应用使用新接口。按需目录 API 使用独立 SchemaOptions／SchemaSnapshot，读取失败为 SchemaMetadataError(stage, cause)，不会自动加载整份目录，详见[Schema 元数据](schema-metadata.md)。

单次选择执行配置使用新的 query_with_profile／query_with_profile_info、prepare_with_profile／prepare_with_profile_info；SessionPrepared 使用 execute_with_profile／execute_with_profile_info／execute_conditional_with_profile。扩展分页使用 pages_with_options，接受所支持的 profile、显式幂等、重试和遍历期限。原 query、prepare、execute、pages 等签名保持 0.2.0 不变；它们在 Builder 设置了默认 profile 时可继承该默认值。单次 options 仍替换整份选项，准备和 Pager 保存选定配置，详见[执行配置](execution-profiles.md)。

分类指数退避与抖动通过 ExecutionProfile 的 RetryBackoff 显式启用；RetryPolicy 两字段及默认固定延迟保留。无论是否使用退避，仍需要每次调用声明幂等，保留次数上限及同一 Deadline。游标容器格式不变，超时和重试预算不写入游标；解析和序列化先校验长度再分配，合法游标不是防篡改凭证。

响应限制由独立 ResponseLimits 配合 Builder 作用域的 response_limits 参数启用；省略时沿用原正文上限。低层需要自定义限制时使用 decode_result_limited、decode_response_limited、read_metadata_limited、read_type_limited 和 DecodeBudget::new_limited；旧函数参数列表不变。超限关闭物理连接，废弃响应在校验帧与编号后跳过正文语义，详见[响应限制](response-limits.md)。

额度等待改为 FIFO，可能出现队首阻塞；心跳不越过排队者，本地额度压力不触发健康控制连接重建。单连接 max_waiting 增加 1048576 的边界上限，非法配置说明参数名与范围。外部缓存列定义通过 checked_columns_snapshot 在等待和监听器前冻结。调度与接收观测使用新增 SchedulingSnapshot／ReceiveMemorySnapshot，不把调用方保留的结果计为驱动交付缓冲。

MetricEvent、RequestOutcome、RequestEvent 和 MetricsSnapshot 保留 0.2.0 形状。扩展事件使用独立 DiagnosticEvent，通过 Metrics::with_diagnostics 订阅；RPC 分类读取 RpcFinished(scope, event, session_budget)，逻辑计数读取 Metrics::operations_snapshot()。认证失败在扩展 ConnectionFailure 中单独标识，旧 RequestOutcome 仍为 OtherFailure；详见[运维诊断](diagnostics.md)。

Builder 的每节点连接池默认仍为 1，可选 1–8。NodeStatus.generation／Session.status().generation 继续计接受的连接代次，初次建池也会增长；按槽诊断使用 Session.pools()。发布前开发分支的旧写法需要迁移到上述新名称，已发布 0.2.0 的业务接口保留。
