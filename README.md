# mooncql

[![Release](https://img.shields.io/github/v/release/prowk/mooncql)](https://github.com/prowk/mooncql/releases/latest)
[![CI](https://github.com/prowk/mooncql/actions/workflows/ci.yml/badge.svg)](https://github.com/prowk/mooncql/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/prowk/mooncql)](LICENSE)

MoonBit 原生异步 Cassandra 驱动，使用正式 Native Protocol v5，面向 native 后端。

- 参数化查询、预处理、批处理、LWT 和自动分页。
- 多路复用、CRC 校验、LZ4、密码认证和经过证书验证的 TLS。
- Session 自动恢复、节点发现、数据中心与 token-aware 路由。
- 有界背压、超时与取消、显式幂等重试、tracing 和指标。
- 类型化 Row、精确数值转换与可恢复分页游标。

## 安装

```sh
moon add prowk/mooncql@0.2.2
moon add moonbitlang/async@0.22.3
```

在应用的 `moon.pkg` 中导入 `moonbitlang/async` 和 `prowk/mooncql/client`；使用查询选项时再导入 `prowk/mooncql/protocol`。需要 MoonBit native 工具链；0.2.2 使用 moonc 0.10.18+6c83a7f62 及配套 core，moon 版本为 0.1.20261028。升级时请先更新工具链；async 依赖仍为 0.22.3，公开 API 保持兼容。

## 快速示例

```moonbit
async fn main {
  @client.with_session(session => {
    guard session.query("SELECT release_version FROM system.local")
      is Rows(page) else {
      fail("expected server version")
    }
    println(page.row(0).text("release_version"))
  })
}
```

默认连接 `127.0.0.1:9042`。完整的建库、参数绑定、预处理和分页示例见[入门教程](docs/getting-started.md)，仓库内可直接运行：

```sh
moon update
docker compose up -d --wait --wait-timeout 360
moon run cmd/tutorial
```

## 文档

[文档目录](docs/README.md) · [入门教程](docs/getting-started.md) · [连接配置](docs/configuration.md) · [升级说明](docs/migration.md) · [API](https://mooncakes.io/docs/prowk/mooncql)

## 兼容性与语义

已验证 Cassandra 5.0.5、Windows 和 Linux native。其他服务端版本及 ScyllaDB 尚未实测。TLS 在 Windows 使用 Schannel，在 Linux 使用 OpenSSL；协议、CRC、LZ4 和请求调度由 MoonBit 实现。

写入默认不自动重放；启用重试须明确声明幂等。超时或取消不代表服务端撤销执行。分页不保证跨页快照一致性。空闲连接默认定期心跳，失败后由 Session 恢复。

## 开发与许可

构建、测试和短时集成验收见[开发指南](docs/development.md)。连续六小时负载和长期内存趋势验证尚未执行。

Apache-2.0，见 [LICENSE](LICENSE)。TLS 适配层保留上游版权与来源说明。
