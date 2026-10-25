# mooncql 文档

适用于 0.2.1。[项目首页](../README.md) · [API](https://mooncakes.io/docs/prowk/mooncql)

## 开始使用

1. [入门教程](getting-started.md)：启动数据库、创建应用、绑定参数、预处理、分页和资源关闭。
2. [连接配置](configuration.md)：认证、TLS、超时、额度和多节点的常用配置。
3. [从 0.1 升级](migration.md)：新增接口与失败语义变化。
4. [三个独立场景](examples.md)：设备事件、批处理核对和已有数据检查。

## 使用指南

| 主题 | 内容 |
| --- | --- |
| [Session 与恢复](session.md) | 作用域、节点状态、重连、资源快照 |
| [连接健康](connection-health.md) | 空闲心跳、半断开识别、关闭和恢复 |
| [TLS](tls.md) | 信任根、名称验证、证书链和客户端身份 |
| [超时与取消](timeouts.md) | 请求阶段、Deadline、迟到响应 |
| [背压](backpressure.md) | 请求数量、字节预算、过载 |
| [响应限制与接收内存](response-limits.md) | 0.2.1 的解码限制、响应所有权与废弃正文策略 |
| [预处理缓存](prepared-cache.md) | LRU、并发准备、元数据 |
| [行与值](rows.md) | 类型化读取、NULL、UUID、日期和精确数值 |
| [分页与游标](paging.md) | 自动续页、恢复上下文、失败语义 |
| [条件写入](conditional-writes.md) | LWT、applied、串行一致性 |
| [批处理](batches.md) | 同分区写入、批类型和重放边界 |
| [重试](retries.md) | 幂等声明、预算和失败历史 |
| [执行信息](execution-info.md) | tracing、warnings、custom payload |
| [指标](metrics.md) | RPC、排队、连接、缓存和监听器 |

## 集群与路由

- [事件订阅](events.md)：REGISTER、拓扑、状态和 schema 事件。
- [拓扑发现](topology.md)：控制连接、系统表、地址映射和刷新。
- [数据中心与 token-aware 路由](routing.md)：分区键、Murmur3、复制策略和安全回退。

## 进阶指南

- [批处理与生命周期](development-api.md)：Session 批处理、动态认证与优雅排空，以及对应的可运行示例。
- [Schema agreement](schema-agreement.md)：0.2.1 的显式检查、DDL 后等待和超时报告。
- [Schema 元数据](schema-metadata.md)：0.2.1 的按需目录、不可变快照、缓存失效和独立对照。
- [请求执行配置](execution-profiles.md)：0.2.1 的不可变配置、单次覆盖、分页策略和遍历预算。
- [节点负载与 Session 总额度](session-limits.md)：0.2.1 的可用额度选择、跨连接预算与后台 RPC 计费。
- [每节点连接池](pooling.md)：0.2.1 的可选多连接、准备与故障隔离、串行恢复和池快照。
- [多数据中心与拓扑变化](multidc.md)：0.2.1 的成员身份替换、过期路由保护和双 DC 实库验收。
- [应用类型映射](value-mapping.md)：0.2.1 的显式结构编解码、嵌套字段路径及缺列／NULL 策略。
- [运维诊断与 Prometheus](diagnostics.md)：0.2.1 的逻辑／RPC 分离、延迟分布、有界标签与排错路径。
- [原生 TLS 与最小权限验收](native-tls-acceptance.md)：0.2.1 的 Cassandra 自身 TLS 监听、双向证书和最小业务授权。

## 开发与验证

- [开发指南](development.md)：构建、回归、CI 和发布检查。
- [申报功能与验收证据](acceptance.md)：功能对应清单、四组合短时验收、故障和类型边界。
- [版本与发布包](versions.md)：历史版、稳定版和独立消费项目验收。
- [v5 协议依据](protocol-v5-regression.md)：固定源码、字节样例和互操作边界。
- [差分测试](differential-tests.md)：独立类型、压缩和状态机校验。
- [性能基准](performance.md)：可复现的测量方法。
- [每节点连接数评估](pooling-evaluation.md)：固定总并发的短时交错测量、原始样本和资源代价。
- [混合负载与故障示例](long-run.md)：短时运行及按需执行的长期验证。

兼容声明限于实际验证的 Cassandra 5.0.5。长期负载测试尚未执行，不由单元测试或短时集成结果替代。
