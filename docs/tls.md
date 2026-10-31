# TLS 连接

[文档目录](README.md) · [入门教程](getting-started.md)

0.2.1 新增的 Cassandra 自身 TLS 监听与最小权限账户测试见[原生 TLS 验收](native-tls-acceptance.md)，与本页的 TLS 代理矩阵分别报告。

本文适用于 0.2.1 和 0.2.2。最低 TLS 版本为 1.2。

`Config::new(tls=TlsConfig::new(...))` 开启 TLS。默认使用系统信任根，始终校验服务端名称；`server_name` 默认等于连接 host。指定 `ca_file` 时，仅使用该 PEM 文件中的 CA 作为信任根。可以将连接地址设置为 IP，同时使用 `server_name` 指定证书中的 DNS 名称；也支持证书的 IP SAN。驱动没有跳过证书验证的配置。

```moonbit
let config = @client.Config::new(
  host="127.0.0.1",
  port=9142,
  tls=@client.TlsConfig::new(
    server_name="cassandra.example.test",
    ca_file="certificates/ca.pem",
  ),
)
@client.with_connection(config~, connection => {
  ignore(connection.query("SELECT release_version FROM system.local"))
})
```

客户端证书通过 `identity` 显式提供：

| 平台 | 形式 | 示例 |
| --- | --- | --- |
| Linux / macOS（OpenSSL） | PEM 证书链和未加密私钥文件 | `ClientIdentity::Pem("client.pem", "client.key")` |
| Windows（Schannel） | 当前用户 My 证书库中带私钥的证书 SHA-1 指纹，40 个十六进制字符 | `ClientIdentity::WindowsStore(thumbprint)` |

Windows 驱动仅打开显式选定的证书，不自动选择当前用户的其他凭据，也不导入或删除凭据。证书的安装及访问权限由部署方管理。指纹在这里用于定位凭据，不用于信任校验或签名算法。OpenSSL 会核对私钥与证书匹配，并发送证书链。

TCP 与 TLS 共用同一套 v5 分片、CRC、压缩、额度、取消及截止时间逻辑。连接超时也覆盖 TLS 握手。错误证书通常返回 `TlsFailure`；服务端拒绝客户端凭据也可能以 TCP 连接中止表现，具体取决于系统 TLS 实现。取消不撤销 Cassandra 执行。

TLS 适配基于固定的官方 async 0.22.3 实现，扩展客户端凭据；密码学与证书验证由 OpenSSL / Schannel 完成。来源、原始哈希和改动范围见 [TLS 适配层说明](../internal/secure/NOTICE.md)。适配使用公共 IO 接口及独立缓冲，不读取运行时私有缓冲区布局。Windows 客户端使用系统 Schannel；Linux/macOS 需可加载的 OpenSSL。

运行验收：

```sh
python -m pip install -r scripts/requirements-tls.txt
python scripts/tls_matrix.py
# 已有本地专用 Cassandra 时，穿过 TLS 终止代理进行真实协议验收：
python scripts/tls_matrix.py --backend-port 9042
```

脚本每次生成私有测试 CA、有效 / 过期服务端证书及受信任 / 不可信客户端证书，均保存在被忽略的 `.tools/tls-fixtures/`。Windows 测试临时导入本次新生成的客户端证书，结束后删除该证书和私钥，不安装测试根 CA。验收覆盖完整中间证书链、缺失中间证书、错误链信任根、DNS / IP 名称、错误名称、不可信 CA、过期证书、双向 TLS、缺失 / 不可信客户端凭据、400000 字节查询，以及取消后的迟到响应。独立 Python 服务核对请求字节和 CRC/LZ4；真实服务端模式通过 TLS 代理转发 Cassandra，不等同于单独验收 Cassandra 自身的 TLS 监听配置。

CI 在 Windows / Linux 运行独立矩阵，在 Cassandra 认证 / 压缩四种组合中运行真实服务端转发矩阵。当前实测服务端版本仍限于 Cassandra 5.0.5。
