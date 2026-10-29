# 开发与验收

[文档目录](README.md) · [协议依据](protocol-v5-regression.md)

## 工具链与本地回归

当前验收工具链为 moonc 0.10.18+6c83a7f62、moon 0.1.20261028、moonbitlang/async 0.22.3，默认目标 native。所有文本文件使用 UTF-8，新代码注释使用中文。

CI 安装前通过 `scripts/precache_nushell.py` 按固定 Nu 0.112.2 发布资产和 SHA256SUMS 校验填充工具缓存，避免上游安装器只搜索第一页 Release 导致冷缓存失败；MoonBit 编译器与 core 版本仍固定为上述版本。

```sh
moon update
python -m pip install -r scripts/requirements-reference.txt
moon check --target native --deny-warn
moon build --target native --deny-warn
moon test --target native --deny-warn
moon info
moon fmt --check
python scripts/protocol_reference.py
python scripts/conversion_reference.py --check
python scripts/check_docs.py
python scripts/check_api.py
python -m unittest discover -s scripts/tests
```

独立类型、LZ4、路由和 TLS 验收：

```sh
python scripts/differential.py
python scripts/routing_reference.py
python scripts/tls_matrix.py
```

TLS 矩阵包含根 CA 直接签发、中间证书链、缺失中间证书、错误信任根、名称与有效期、双向 TLS、大消息和取消。Windows 仅为双向测试临时安装本次生成的客户端证书，并在结束时删除。

统一入口可先预检，再按组顺序执行：

```sh
python scripts/local_acceptance.py --preflight --group unit --group reference
python scripts/local_acceptance.py --group unit --group reference
python scripts/local_acceptance.py --preflight --group single --group cluster --group multidc --group native-tls --skip-unavailable
python scripts/local_acceptance.py --group single --group native-tls
```

unit 包含 native、Python、API、文档和固定种子模拟；reference 包含独立协议、类型、路由和本地 TLS。数据库组依赖 Docker，并检查端口、宿主和 Docker 内存；cluster／multidc 使用保守的 6 GiB 可用内存门槛。数据库组持有同一个本地锁，使用唯一 Compose 项目名逐组启动和清理，不接管已占用端口或默认项目。超时／中断会终止本次子进程组，finally 清理自己的容器和卷；证书由现有 TLS 上下文清理，不创建网络规则。跳过或只预检均不会产生 passed=true。源码摘要、工具链、种子、组状态和失败日志写入 `.artifacts/local-acceptance-*`，不要把它们提交。

文档检查覆盖本地链接、统一导航，以及 README、入门、开发接口与结构映射片段和可编译源码的一致性。README 原片段位于 `cmd/readme`，无认证实库 CI 会直接运行；独立稳定版消费项目也会编译同一片段。历史 0.1 项目继续使用自身支持的示例，不混入 Session。

`check_api.py` 将七个公开包与固定 v0.2.0 标签对照，并核对 [api-compatibility.json](../fixtures/api-compatibility.json)。检查包括调用签名、公开记录字段、枚举／错误分支与导出实现，不把不透明类型私有字段的变化当作构造接口变化。补丁版本禁止修改或删除稳定声明；扩展选项必须使用独立新增接口。审阅 `moon info` 和[迁移说明](migration.md)后才用 `--update` 更新新增声明合同，该参数不能绕过稳定声明保护。

完整发布包验收还运行 `moon package --frozen` 和 `python scripts/patch_compatibility.py`。后者在独立模块先安装实际 0.2.0，逐文件核对标签和运行时源码，再实编译五种旧完整记录和五类穷尽匹配；随后在隔离 workspace 中将该应用的依赖指向未经修改的候选归档，复编旧接口、README、三个场景和新 Builder 示例。该 workspace 仅用于候选验证，不冒充注册表已发布包。发布后仍须真实安装 0.2.1。原生回归另断言旧入口能同时持有 130 个 RPC，避免不经意引入新的全局 128 个默认上限。接口检查不能替代默认值、取消、重试或协议行为的回归。

本地 TCP 模拟组件集中在 `client/test_node_test.mbt`：所有模拟用例复用 Peer、握手及编解帧，FaultBarrier 对 OPTIONS、STARTUP、AUTH_RESPONSE、业务写入、首段响应和关闭提供带阶段名称的有界同步；write_chunks 可逐字节拆分。损坏 CRC、合帧、迟到响应和半帧 EOF 可组合，不以固定 sleep 作为竞争发生的唯一依据。每个用例仍须用外层总超时与任务组收尾本次服务器。

状态机默认种子为 2026101819、32 轮；`CQL_TEST_SEED` 可设置 UInt 种子，`CQL_TEST_ROUNDS` 可设置 1–256 轮。失败会打印种子、轮次及精确单轮重放参数。普通 CI 另外执行 2026102501 的 16 轮固定集合。`client/resource_cycles_test.mbt` 执行 100 轮 Session、准备、分页、发送后取消、排空和关闭，包含应用保留旧 Prepared／Pager；断言每轮额度与任务句柄归零。这是短时逻辑所有权回归，不能据此断言长期 RSS 无增长。

每轮独立派生随机状态，`CQL_TEST_CASE` 可只重放某轮；失败日志同时给出并发数、取消次数和分片宽度。`python scripts/replay_model.py --seed 2026102501 --case 15 --shrink` 先复现，再仅保留仍触发性质失败的有界参数缩减，编译失败不会误作复现。缩减不保证得到全局最小反例。

## 真实数据库集成

以下命令只针对仓库的专用 Cassandra 环境；cmd/integration 会创建或清空 mooncql_test 的测试数据。

```sh
docker compose up -d --wait --wait-timeout 360
moon run cmd/integration
python scripts/interop.py
python scripts/tls_matrix.py --backend-port 9042
python scripts/session_recovery.py --docker-compose
docker compose down
```

CI 覆盖 Windows 与 Linux 本地回归、无认证与密码认证、普通帧与 LZ4 四种数据库组合，以及三节点发现和故障恢复。三节点运行方式见[拓扑](topology.md)和[Session](session.md)。

另覆盖[双 DC](multidc.md)、[原生 TLS 与最小权限](native-tls-acceptance.md)及[Prometheus 格式](diagnostics.md)。它们与 TLS 代理、独立模拟和实际 Cassandra 的证据分别归档。

需要机器可读的短时验收报告时，运行 `python scripts/short_acceptance.py --docker-matrix`；已有专用实例可选择单组。发布包独立消费检查为 `python scripts/package_acceptance.py`，增加 `--run` 可运行两个已发布版本的三个场景。CI 在失败时也归档原始结果和日志，详见[申报验收](acceptance.md)及[版本验收](versions.md)。

普通功能修改主要检查本地源码及相关集成；发布前、修改消费示例或依赖配置时执行完整发布包验收。CI 根据差异决定是否安装历史／稳定包，手动运行 checks 或推送标签时强制执行。

## 发布检查

1. 模块元数据、STARTUP 上报版本与更新记录保持一致。
2. 完成本地回归、独立互操作及 CI 集成，核对生成接口的变化。
3. 按[入门教程](getting-started.md)构建并运行独立应用。
4. 用 `moon package --list` 检查归档，排除本地计划、草稿、凭据、日志、原始测试产物和构建目录；再运行 `moon publish --dry-run`。
5. 从验收通过的同一提交创建 GitHub Release 并发布 Mooncakes 包。

`.gitignore` 控制源码提交，`.moonignore` 控制运行时包；只增加忽略规则不会自动移除已经跟踪的文件。用户文档保留在 docs，参考字节与独立测试脚本保留在源码仓库；开发过程产物只保存在本地忽略目录。

## 验证边界

兼容声明限于实际验收的 Cassandra 5.0.5。短时集成和故障测试不等同于长期稳定性证明；连续六小时混合负载及长期内存趋势尚未执行，只有明确安排时才运行[长期验证](long-run.md)。

工具链升级会将内建类型 Int／UInt 的源码和生成接口规范化为 Int32／UInt32，两组名称分别是同一内建类型的别名。API 审计只在类型表达式中统一这些名称，仍检查枚举分支、字段、参数标签和限定类型的真实变化；旧完整记录与穷尽匹配还须通过候选归档实编译。
