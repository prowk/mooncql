# mooncql

用 MoonBit 实现的 Cassandra CQL 原生协议 v4 异步驱动，当前为实验性初版。协议编解码由 MoonBit 实现，原生 TCP 使用官方 `moonbitlang/async`，连接一个明确配置的 Cassandra 协调节点。

## 已实现

- OPTIONS／STARTUP 握手，无认证和 PasswordAuthenticator 密码认证。
- 参数化 QUERY、PREPARE／EXECUTE、每连接最多缓存 64 条预处理语句。
- stream id 多路复用、有界在途请求、写入串行化及作用域内的连接生命周期。
- 普通查询和预处理查询的惰性分页；空页仍按 paging state 继续。
- 中文文本、blob、布尔、整数、浮点、UUID、timeuuid、inet、日期和时间。
- bigint／timestamp 使用 Int64；decimal 与 varint 保留精确的有符号字节表示。
- list／set／map、tuple、UDT；预处理参数校验、嵌套上限和分页绑定深拷贝。
- 保留服务端错误详情、warnings、tracing id 和 custom payload。
- 超时、取消、EOF、异常帧均结束等待请求；UNPREPARED 最多恢复一次。

当前不提供 TLS、压缩、协议 v5、BATCH、自动重连、多节点连接池、拓扑发现或智能路由。其他 Cassandra 版本及 ScyllaDB 尚未实测。请使用完整限定表名，例如 `app.events`；不支持在共享连接中通过 `USE` 切换 keyspace。

## 运行示例

已实测工具链：`moonc 0.10.14+7d59c7ec9`、`moon 0.1.20260920`、`moonbitlang/async 0.22.3`。默认后端为 native；已在 Windows 原生客户端上连接 WSL 中的 Cassandra 5.0.5。Linux／Windows CI 工作流已配置，远端执行结果需以对应任务为准。

使用 Docker 或本地 Cassandra 提供测试服务：

```sh
docker compose up -d --wait
moon run cmd/main
```

默认连接 `127.0.0.1:9042`。可通过 `CQL_HOST`、`CQL_PORT`、`CQL_USERNAME`、`CQL_PASSWORD` 配置示例与集成入口；认证信息不会由示例打印。服务器启用 PasswordAuthenticator 时，可在 PowerShell 中设置：

```powershell
$env:CQL_HOST = '127.0.0.1'
$env:CQL_PORT = '9042'
$env:CQL_USERNAME = 'your-user'
$env:CQL_PASSWORD = 'your-password'
moon run cmd/main
```

项目尚未发布到 Mooncakes。库入口为 `broti/mooncql/client`；值类型和查询选项分别位于 `broti/mooncql/types`、`broti/mooncql/protocol`。

```moonbit
async fn main {
  @client.with_connection(connection => {
    let statement = connection.prepare(
      "SELECT id, message FROM app.events WHERE device=?",
    )
    let pages = statement.pages(
      [Integer(42)],
      options=@protocol.QueryOptions::new(page_size=100),
    )
    while pages.next() is Some(page) {
      for i = 0; i < page.rows.length(); i = i + 1 {
        let message = page.get(i, "message")
        // 按应用需要匹配 Text、Null 等值类型。
        ignore(message)
      }
    }
  })
}
```

调用包需导入 `moonbitlang/async`、`broti/mooncql/client`、`broti/mooncql/protocol` 和 `broti/mooncql/types`。`with_connection` 负责关闭连接及收发任务，推荐作为入口；`connect` 返回的连接只执行串行交换，调用方需要显式 `close`。返回的 Prepared／Pager 不能跨连接使用，也不能在作用域结束后继续访问网络。

## 失败语义与边界

超时或取消后会关闭整条连接，使其他在途请求明确失败。连接失效后由应用重新调用 `with_connection`；普通写请求不会自动重放，取消也不表示数据库未执行该请求。

只有服务端返回匹配语句 ID 的 UNPREPARED 时，才会重新 PREPARE 并重试一次 EXECUTE。其他服务端错误通过 `@client.Server(error)` 返回，正常业务错误不会关闭连接。低层 `request` 返回 Reply，供调用方读取 warnings 等附加信息。

默认单帧正文上限为 16 MiB，最大在途请求数为 128，可通过 Config 调整；类型和值递归最多 32 层。每个 Pager 仅允许一个活动的 `next` 调用。decimal 表示为 `Decimal(scale, signed_big_endian_bytes)`，varint 同样保留二进制有符号整数；set／map 使用数组表示，不保证元素顺序。

## 验证

单元和本地 TCP 模拟测试无需 Cassandra：

```sh
moon check --target native --deny-warn
moon test --target native --deny-warn
moon info
moon fmt --check
```

测试覆盖反序响应、拆包粘包、挂起读取的取消顺序、在途背压、半帧断连、非法长度、服务端认证、预处理失效恢复及分页状态。

真实数据库集成入口创建并清空专用的 `mooncql_test.events` 表，默认并发预处理写入 10,000 条设备事件，再逐页核对全部字段、更新和删除行为：

```sh
moon run cmd/integration
```

`CQL_ROWS` 可调整记录数，范围为 1–100000。已在 Cassandra 5.0.5 的无认证及密码认证模式下各完成 10,000 条写读验证：普通分页 89 页，预处理分页完整读取 10,000 行，ID 校验和 49995000。

在 Python 3.11+ 的独立虚拟环境中安装参考驱动，进一步交叉验证：

```sh
python -m pip install -r scripts/requirements-reference.txt
python scripts/interop.py
```

该脚本先用 Python 驱动独立核对 MoonBit 写入的全部数据，再写入不同 CQL 类型，调用 `cmd/interop` 由 MoonBit 核对并回写，最后由 Python 确认结果。两种认证模式均已通过。测试数据、临时运行时和本地日志均不纳入版本控制。

结束 Docker 测试环境：

```sh
docker compose down
```

## 依据

- [Apache CQL binary protocol v4](https://github.com/apache/cassandra/blob/cassandra-4.1/doc/native_protocol_v4.spec)
- [Apache GoCQL](https://github.com/apache/cassandra-gocql-driver)
- [MoonBit async](https://github.com/moonbitlang/async)

Apache-2.0，见 LICENSE。
