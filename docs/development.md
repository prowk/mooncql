# 开发与验收

[文档目录](README.md) · [协议依据](protocol-v5-regression.md)

## 工具链与本地回归

当前验收工具链为 moonc 0.10.14+7d59c7ec9、moon 0.1.20260920、moonbitlang/async 0.22.3，默认目标 native。所有文本文件使用 UTF-8，新代码注释使用中文。

```sh
moon update
moon check --target native --deny-warn
moon test --target native --deny-warn
moon info
moon fmt --check
python scripts/protocol_reference.py
python scripts/conversion_reference.py --check
python -m unittest discover -s scripts/tests
```

独立类型、LZ4、路由和 TLS 验收：

```sh
python -m pip install -r scripts/requirements-reference.txt
python scripts/differential.py
python scripts/routing_reference.py
python scripts/tls_matrix.py
```

TLS 矩阵包含根 CA 直接签发、中间证书链、缺失中间证书、错误信任根、名称与有效期、双向 TLS、大消息和取消。Windows 仅为双向测试临时安装本次生成的客户端证书，并在结束时删除。

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

## 发布检查

1. 模块元数据、STARTUP 上报版本与更新记录保持一致。
2. 完成本地回归、独立互操作及 CI 集成，核对生成接口的变化。
3. 按[入门教程](getting-started.md)构建并运行独立应用。
4. 用 `moon package --list` 检查归档，排除本地计划、草稿、凭据、日志、原始测试产物和构建目录；再运行 `moon publish --dry-run`。
5. 从验收通过的同一提交创建 GitHub Release 并发布 Mooncakes 包。

`.gitignore` 控制源码提交，`.moonignore` 控制运行时包；只增加忽略规则不会自动移除已经跟踪的文件。用户文档保留在 docs，参考字节与独立测试脚本保留在源码仓库；开发过程产物只保存在本地忽略目录。

## 验证边界

兼容声明限于实际验收的 Cassandra 5.0.5。短时集成和故障测试不等同于长期稳定性证明；连续六小时混合负载及长期内存趋势尚未执行，只有明确安排时才运行[长期验证](long-run.md)。
