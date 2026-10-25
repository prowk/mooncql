# Schema agreement

[文档目录](README.md) · [批处理与生命周期](development-api.md) · [执行信息](execution-info.md)

本页接口自 0.2.1 提供，0.2.0 不包含这些接口。

## 显式检查和等待

`session.check_schema_agreement(deadline?)` 读取本 Session 每个存活业务连接的 `system.local.schema_version`。`session.wait_schema_agreement(deadline?)` 周期性重试检查，直到收敛或预算结束。两者返回独立的 `SchemaAgreement` 报告：

| 状态 | 含义 |
| --- | --- |
| `Agreed` | 本轮所有参与节点均取得有效版本，版本相同，且检查期间连接成员没有改变 |
| `Disagreed` | 所有参与节点都有有效版本，但存在不同版本 |
| `Unknown` | 没有存活参与者、版本缺失／读取失败，或检查期间成员发生变化 |

`observations` 保存每个参与者的 Endpoint、连接 generation、UUID 和错误；`excluded` 列出未连接或已断开的节点。`membership_changed` 标明检查期间的连接替换；`timed_out` 独立标明预算是否耗尽。权限拒绝返回 Unknown 和原始结构化错误，不无限重复无权限查询，也不阻止随后普通业务查询。

检查范围是 **Session 当前已知且存活的节点**。只配置一个 contact point、未启用发现时，Agreed 仅证明该参与范围，不代表尚未知晓的整个集群。生产多节点场景应启用发现或配置完整参与节点，并检查 observations／excluded。没有参与者时绝不将空集合当作成功。

## 可配置的 DDL 后等待

在 `SessionBuilder::new(schema_agreement=SchemaAgreementConfig::new(wait_after_ddl=true))` 开启自动等待。当前开发示例 [cmd/features](../cmd/features/main.mbt)包含可编译配置。

| 配置 | 默认值 | 语义 |
| --- | --- | --- |
| `wait_after_ddl` | false | 保留默认查询时延；显式开启后，成功 SchemaChanged 响应触发等待 |
| `timeout_ms` | 10000 | schema 等待上限，仍受原查询总 Deadline 的剩余时间限制 |
| `poll_interval_ms` | 100 | 检查间隔，范围 1–60000 毫秒 |
| `max_nodes` | 1024 | 本轮最多检查的存活节点数，范围 1–65536；超限报告 Unknown 和限制错误 |

成功 DDL 的结果和等待结果分别保留：使用新增的 `query_with_schema_info` 读取 SchemaExecution 的 `execution.value` 与 `execution.schema_agreement`，原业务信息仍在 `execution.info`。稳定接口 `query_with_info` 继续返回只有 value／info 的 Execution，不扩展 ExecutionInfo 的公开记录字段；显式开启等待时仍会等待，但需要读取等待报告的应用使用新接口。即使 schema 尚未收敛或等待超时，value 仍然是已经成功的 SchemaChanged，`attempt_count` 仍描述原业务请求，等待过程不会重新发送 DDL。后续操作是否继续由应用决定。

普通 `query` 使用同样的可选等待，但只返回业务结果；需要判断收敛状态时应使用 `query_with_info`。默认关闭自动等待的调用、Connection 接口和原始 `Session.request` 保持原有行为；原始入口需要显式调用检查方法。服务端没有返回 SchemaChanged 的无变化操作不附加等待。

多节点先建表／修改 UDT、确认 agreement 为 Agreed，再准备读取语句，可避免下一个协调节点尚未看到定义。[三节点集成入口](../cmd/cluster/main.mbt)实际验证 CREATE TYPE、ALTER TYPE、建表、准备与 UDT 写读顺序，并断言每次报告包含三个独立节点。

这与 [Apache Java Driver 的 schema agreement](https://apache.github.io/cassandra-java-driver/4.19.0/core/metadata/schema/#schema-agreement)使用相同的基本判据：检查存活节点的 schema version，等待失败本身不否定已经成功的 DDL。跨不同服务端版本时可能长期不收敛，驱动不猜测或改写版本 UUID。

## 验证

```sh
moon test --target native --deny-warn
moon run cmd/features
python scripts/short_acceptance.py --auth password --compression lz4
```

[确定性回归](../client/schema_agreement_test.mbt)涵盖多节点一致／分歧、NULL 版本、代次替换、元数据权限拒绝、默认不等待，以及 DDL 耗时与后续等待共用总 Deadline。真实三节点由现有 CI 的 cluster 工作流执行，不启动长期负载测试。
