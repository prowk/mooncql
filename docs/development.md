# 开发与验收

[文档目录](README.md) · [协议依据](protocol-v5-regression.md)

## 工具链与本地回归

当前验收工具链为 moonc 0.10.14+7d59c7ec9、moon 0.1.20260920、moonbitlang/async 0.22.3，默认目标 native。所有文本文件使用 UTF-8，新代码注释使用中文。

CI 安装前通过 `scripts/precache_nushell.py` 按固定 Nu 0.112.2 发布资产和 SHA256SUMS 校验填充工具缓存，避免上游安装器只搜索第一页 Release 导致冷缓存失败；MoonBit 编译器与 core 版本仍固定为上述版本。

```sh
moon update
python -m pip install -r scripts/requirements-reference.txt
moon check --target native --deny-warn
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

文档检查覆盖本地链接、统一导航，以及 README、入门、开发接口与结构映射片段和可编译源码的一致性。README 原片段位于 `cmd/readme`，无认证实库 CI 会直接运行；独立稳定版消费项目也会编译同一片段。历史 0.1 项目继续使用自身支持的示例，不混入 Session。

`check_api.py` 将七个公开包与固定 v0.2.0 标签对照，并核对 [api-compatibility.json](../fixtures/api-compatibility.json)。检查包括调用签名、公开记录字段、枚举／错误分支与导出实现，不把不透明类型私有字段的变化当作构造接口变化。当前审计为 114 项新增声明、23 项既有声明变化、无删除；变化已在[迁移说明](migration.md)记录。后续修改接口时先审阅 `moon info` 差异及迁移说明，再用 `python scripts/check_api.py --update` 更新合同；未审阅的新差异会使 CI 失败。该检查不能替代默认值、取消、重试或协议行为的回归。

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

开发分支另覆盖[双 DC](multidc.md)、[原生 TLS 与最小权限](native-tls-acceptance.md)及[Prometheus 格式](diagnostics.md)。它们与 TLS 代理、独立模拟和实际 Cassandra 的证据分别归档。

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
