# 申报功能与验收证据

[文档目录](README.md) · [版本与发布包](versions.md) · [场景示例](examples.md)

本页对应已提交申报书的功能与交付承诺，不修改申报书。申报指定版本是 **0.1.0**；当前稳定版是 **0.2.1**。下表中的源码与回归入口是仓库当前版本，历史实现以对应发布标签为准。

## 功能对应清单

| 申报功能 | 源码 | 回归与实库证据 | 运行命令 |
| --- | --- | --- | --- |
| 正式 v5 envelope、外层帧、CRC24／CRC32、LZ4、拆包和重组 | [framing](../framing/frame.mbt)、[重组](../protocol/decoder.mbt)、[协商](../client/connection.mbt) | [固定协议](../protocol/reference_test.mbt)、[帧边界](../framing/frame_test.mbt)、[认证切帧与大消息](../client/v5_test.mbt) | `moon test --target native --deny-warn`；`python scripts/protocol_reference.py` |
| OPTIONS／STARTUP、无认证和 PasswordAuthenticator | [握手](../client/connection.mbt) | [认证和并发](../client/connection_test.mbt)、[协商失败](../client/negotiation_test.mbt)、实库四组合 | 单组合或四组合短时验收，见下文 |
| 参数化、命名绑定、keyspace、一致性、timestamp 和 now_in_seconds | [请求编码](../protocol/request.mbt)、[连接](../client/connection.mbt) | [请求字节](../protocol/request_test.mbt)、[实库 v5](../cmd/integration/v5.mbt)、[有符号时间戳](../cmd/integration/health.mbt) | `moon run cmd/integration` |
| PREPARE／EXECUTE、按 keyspace 缓存、ID 匹配的单次恢复 | [Prepared](../client/prepared.mbt)、[缓存](../client/prepare_cache.mbt) | [缓存隔离](../client/v5_test.mbt)、[单次恢复](../client/failures_test.mbt)、[错误 ID 和 BATCH 禁止恢复](../client/write_semantics_test.mbt) | `moon test --target native --deny-warn` |
| 普通和预处理惰性分页、空页和结束游标 | [Pager](../client/pager.mbt) | [空页](../client/statements_test.mbt)、[分页边界](../client/paging_cursor_test.mbt)、[10000 行逐字段断言](../cmd/integration/main.mbt) | `python scripts/short_acceptance.py --auth none --compression none` |
| logged／unlogged／counter BATCH | [批处理](../client/batch.mbt)、[编码](../protocol/batch.mbt) | [三种结果读取](../cmd/integration/v5.mbt)、[混合批处理场景](../examples/batch-audit/main.mbt)、[故障矩阵](../client/write_semantics_test.mbt) | `moon run examples/batch-audit`；短时四组合 |
| 标量、Int64、decimal／varint、duration、多层集合／tuple／UDT | [值类型](../types/value.mbt)、[验证](../types/validation.mbt)、[转换](../types/conversion.mbt) | [独立边界语料](../scripts/differential_boundaries.py)、[差分](../scripts/differential.py)、[Python 双向互操作](../scripts/interop.py) | `python scripts/differential.py`；`python scripts/interop.py` |
| 元数据变化、旧响应隔离和 NO_METADATA | [结果解码](../protocol/response.mbt)、[元数据接受](../client/prepared.mbt) | [旧 ID](../client/v5_test.mbt)、[旧响应与省略元数据交错](../client/metadata_interleaving_test.mbt)、[实库 ALTER TABLE](../cmd/integration/v5.mbt) | 原生回归；短时四组合 |
| 结构化错误、warnings、tracing、custom payload、长度和深度边界 | [响应](../protocol/response.mbt)、[扩展](../protocol/extensions.mbt) | [错误](../protocol/response_test.mbt)、[执行信息](../client/execution_test.mbt)、[严格非法语料](../scripts/differential_boundaries.py) | 原生回归；独立差分 |
| 并发 stream、背压、取消、超时、EOF、作用域资源回收；未知写入不重放 | [收发](../client/multiplex.mbt)、[额度](../client/admission.mbt)、[Deadline](../client/deadline.mbt) | [故障组合](../client/write_semantics_test.mbt)、[乱序模型](../client/state_machine_test.mbt)、[生命周期](../client/resources_test.mbt)、[Session 重放边界](../client/retry_test.mbt) | `moon test --target native --deny-warn` |
| 公开包、Release、源码、许可、分层 API、Windows／Linux | [版本合同](../fixtures/releases.json)、[消费验收](../scripts/package_acceptance.py)、[CI](../.github/workflows/ci.yml) | 干净消费项目的包源码／API 哈希、构建和三场景运行结果 | `python scripts/package_acceptance.py --run` |

## 版本边界

0.1.0 的承诺是一个显式协调节点、native 后端与 v5 基础驱动。其 55 项测试属于历史发布记录，不是当前分支的测试数量。0.1.0 超时和取消会关闭整条连接，不能套用新版本“保留 stream 并排空迟到响应”的行为。

后续增强包括 TLS、Session 恢复、拓扑发现、路由、幂等重试、可恢复分页游标、类型化 Row、观测指标和空闲心跳。这些不能倒算为 0.1.0 已提供的功能。当前 Session 仍默认不重放普通写入；BATCH 即使显式声明幂等，也不自动重放。此次变更补验收入口与回归，不改写已发布包或移动历史标签。

## 短时实库验收

安装 [固定的独立依赖](../scripts/requirements-reference.txt)，使用专用 Cassandra 5.0.5。入口会创建或清空 **mooncql_test** 测试表，不应指向业务环境。

```sh
python -m pip install -r scripts/requirements-reference.txt
python scripts/short_acceptance.py --docker-matrix
```

该命令为自有 Compose 项目依次运行无认证／密码认证 × 普通帧／LZ4 四组，每组严格固定 10000 行。每组结束时只关闭、删除该项目的容器和卷；默认使用本机 9042 端口。已有专用实例可通过 `CQL_HOST`、`CQL_PORT`、`CQL_USERNAME` 和 `CQL_PASSWORD` 指定，运行单组：

```sh
python scripts/short_acceptance.py --auth password --compression lz4
```

脚本读取实际服务器认证配置、核对协议版本，逐字段检查普通与预处理分页的有序 ID、记录数、校验和 **49995000** 及最后 paging state。另有 400000 字节往返、三种 BATCH 结果、TTL 的存活和过期、schema 更新、Python 双向核对。任一子进程或断言失败都会使命令非零退出，并保留 `passed=false` 的报告。

申报中的 **89 页** 对应 10000 行、`page_size=113`、并发写入 32、清空后的同一 `device=42` 分区、Cassandra 5.0.5。报告保存各页实际行数和终止状态，同时给出 `matches_claim`。服务端允许提前返回短页，因此页数不是数据完整性的替代判据；页数不同仍必须通过所有行、字段、无重复、无漏行和结束游标断言，并明确报告差异。

产物位于 `.artifacts/short-acceptance-*`：`integration.json`、`interop.json`、每组与总 `result.json`、进程日志。报告包含 Git 提交、工作树状态、源树指纹、Moon／moonc、Python、操作系统、Cassandra 与参考驱动版本。CI 无论成功或失败均上传这些产物；原始日志不进入源码提交。

## 故障与差分边界

确定性 TCP 回归覆盖 QUERY 和三种 BATCH 的排队取消、部分发送取消／断线、完整发送后取消与迟到响应、服务端错误后不重发、并发乱序成功／错误响应。Session 回归另外检查断线恢复后不会重发未知写入，低层入口的语义保持独立。匹配 ID 的 UNPREPARED 最多恢复一次，错误 ID 和批处理直接返回错误。

差分以 Cassandra Python Driver 3.30.0 和 python-lz4 4.4.5 为独立参考，固定随机种子 2026101819，并增加具名边界：多层 map／list／tuple／UDT、标量 NULL／空值、根绑定 UNSET、1001 位正负 varint／decimal、Int64 两端及 duration 同号极值。非法集合长度、截断字段、结果中的 UNSET、异号 duration 和超深类型必须失败；深度边界样例 2026102201 固定保留，不能仅靠随机输入“恰好通过”。

本页全部入口均为短时验证。至少 6 小时的混合负载和周期故障测试仍按用户要求暂缓。
