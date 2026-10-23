# Cassandra 原生 TLS 与最小权限验收

[文档目录](README.md) · [TLS 配置](tls.md) · [运维诊断](diagnostics.md) · [开发指南](development.md)

本页是**尚未发布开发分支**的专用短时集成入口，服务端固定 Cassandra 5.0.5。它直接连接 Cassandra 自己的 TLS 监听，独立于现有 Python TLS 服务／TLS 终止代理矩阵；结果不合并成同一种测试。

## 运行

需要 Docker Compose、Python 3.11 和 MoonBit 原生工具链。宿主机 19064 端口必须空闲，脚本为每次运行创建唯一 Compose 项目、测试证书和专用数据卷：

```sh
python -m pip install -r scripts/requirements-reference.txt
python scripts/native_tls_acceptance.py --docker-compose
```

脚本自行启动、重启和关闭自己的集群，不操作已有业务实例。容器使用 768 MiB JVM 堆、`ActiveProcessorCount=2`，还需要非堆、缓存和 Docker 资源。失败时也尝试归档日志、回收客户端身份和关闭专用项目／数据卷；关闭成功才允许通过报告。

证书和密钥写入忽略的 `.tools/native-tls-*`；报告、各用例日志及服务端日志写入 `.artifacts/native-tls-*`，CI 仅归档后者。报告包含 `listener="Cassandra native TLS"`、`proxy_used=false`、工具链、源码指纹、用例与关闭状态，不保存账户密码或私钥。

## 原生 TLS 矩阵

Cassandra 在原生端口 9042 开启 `client_encryption_options.enabled=true`、`optional=false`，映射到宿主机 19064。不使用已经弃用的额外 `native_transport_port_ssl`，配置依据[固定 Cassandra 5.0.5 配置](https://github.com/apache/cassandra/blob/c8abc9f3e1bb46bc4d699c3a167e43df62b9bec8/conf/cassandra.yaml)。

| 模式 | 普通帧与 LZ4 各自验证 |
| --- | --- |
| 单向 TLS | DNS／IP 名称校验与 400000 字节双向消息；错误名称和不可信 CA 被拒绝 |
| 双向 TLS | 受信任客户端身份、DNS／IP 和大消息；缺失或不可信客户端身份被拒绝 |

共十六个 TLS 用例。切换双向模式时停止并重启同一专用 Cassandra，明确设置 `require_client_auth=true` 与 PKCS12 信任库。独立 Python Driver 在拒绝用例后核对 TLS／认证监听仍可用，避免把服务停机算作证书拒绝。

Windows 驱动使用 Schannel，脚本临时导入自己新生成的客户端 PFX，并在每个用例结束后删除该证书与私钥；不安装测试根 CA。Linux 使用 PEM 客户端证书与私钥，CA 通过连接配置显式提供。

服务端保持 PasswordAuthenticator；双向 TLS 证书检查通过后仍需用户名／密码。该测试不声明已经兼容 Cassandra MutualTlsAuthenticator 等独立认证插件。

## 最小权限账户

脚本启用 CassandraAuthorizer，创建非 superuser 的专用登录账户，只显式授予 `mooncql_permissions.business` 表上的 SELECT 与 MODIFY，并通过管理员 `LIST ALL PERMISSIONS` 核对恰好两项授权。

[cmd/least-privilege](../cmd/least-privilege/main.mbt) 在两种 TLS 模式及普通／LZ4 下共运行四次：准备并绑定业务写入、读取逐字段核对、确认其他业务表与 CREATE TABLE 返回 UNAUTHORIZED、读取按需 schema、发现单节点并再次查询，最后排空任务与额度。

**Cassandra 的系统表权限有固定例外。** 5.0.5 将 system.local、peers／peers_v2、schema 等表固定为认证用户可读，见[固定 ClientState 实现](https://github.com/apache/cassandra/blob/c8abc9f3e1bb46bc4d699c3a167e43df62b9bec8/src/java/org/apache/cassandra/service/ClientState.java)。普通 REVOKE 不能关闭这些读取。因此实库报告如实记录公共系统元数据可读，同时证明业务数据和 DDL 仍受授权约束；不能把它说成“系统表权限拒绝已实测”。

对定制授权或兼容服务返回元数据 UNAUTHORIZED 的情况，另用确定性 TCP 响应回归：

```sh
moon test client/metadata_permissions_test.mbt --target native --deny-warn
```

该测试分别开启／关闭发现：按需 schema 返回包含原始服务端错误码的 SchemaMetadataError；schema agreement 返回 Unknown 与拒绝原因，不一直轮询到超时；控制连接记录错误并保持 stale；显式业务节点仍可完成普通查询。关闭后资源归零。已有 schema 回归还检查 DDL 成功后的元数据拒绝不会导致 DDL 重放。

原生监听、TLS 代理和模拟权限拒绝各自保留独立证据；这些短时测试不替代暂缓的六小时混合故障测试。
