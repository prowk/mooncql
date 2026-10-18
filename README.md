# mooncql

用 MoonBit 原生实现的 **Cassandra Native Protocol v5 异步驱动**。协议编解码、CRC 和 LZ4 块压缩均由 MoonBit 实现，原生 TCP 使用官方 `moonbitlang/async`。发布版 0.1.0 连接单个明确配置的协调节点，main 分支另提供显式多节点 Session。服务端需要支持正式 v5 协议。

## 能力

- v5 外层帧与消息 envelope 分层；CRC24 帧头校验、带 Cassandra 固定前缀的 CRC32 载荷校验。
- 普通帧、LZ4 压缩帧、协商压缩后的原始载荷、大消息分片重组、单帧多消息与 TCP 拆包。
- OPTIONS／STARTUP 握手、无认证及 PasswordAuthenticator；在 READY／AUTHENTICATE 后切换帧格式。
- 参数化 QUERY、命名绑定、PREPARE／EXECUTE，以及 logged／unlogged／counter BATCH。
- 按请求指定 keyspace、32 位查询标志、`now_in_seconds`、一致性级别、串行一致性和默认时间戳。
- 每连接最多缓存 64 条预处理语句，缓存区分 keyspace；传递结果元数据 ID，并处理元数据变化通知。
- stream id 多路复用、有界在途请求、写入串行化及作用域内的连接生命周期。
- 普通查询和预处理查询的惰性分页；空页仍按 paging state 继续，绑定值与命名列表保持快照。
- 中文文本、blob、布尔、整数、浮点、UUID、timeuuid、inet、日期、时间与 duration。
- bigint／timestamp 使用 Int64；decimal 与 varint 保留精确的有符号字节表示。
- list／set／map、tuple、UDT，预处理绑定校验与嵌套上限。
- 服务端结构化错误，包括读写失败原因映射和 CAS 争用信息；保留 warnings、tracing id、custom payload。

已发布的 0.1.0 不提供 TLS、自动重连、多节点连接池、拓扑发现或智能路由。main 分支新增功能与发布版本的区别见下文。已实测 Cassandra 5.0.5；其他 Cassandra 版本及 ScyllaDB 尚未实测。

## 快速运行

工具链：`moonc 0.10.14+7d59c7ec9`、`moon 0.1.20260920`、`moonbitlang/async 0.22.3`。默认后端为 native。安装依赖：`moon add prowk/mooncql@0.1.0`。

Docker 测试环境限定为 v5，默认无认证：

```sh
docker compose up -d --wait
moon run cmd/main
```

默认连接 `127.0.0.1:9042`。示例和集成入口支持 `CQL_HOST`、`CQL_PORT`、`CQL_USERNAME`、`CQL_PASSWORD`；设置 `CQL_COMPRESSION=lz4` 开启 LZ4。PowerShell 示例：

```powershell
$env:CQL_PORT = '9042'
$env:CQL_COMPRESSION = 'lz4'
moon run cmd/main
```

需要 Docker 密码认证时，在启动前设置 `CQL_AUTHENTICATOR=PasswordAuthenticator`；使用专用测试实例的默认账户 `cassandra`／`cassandra` 设置 `CQL_USERNAME` 和 `CQL_PASSWORD`，再运行示例。已有实例应先 `docker compose down` 再启动，配置才会生效。

## 库用法

导入 `moonbitlang/async`、`prowk/mooncql/client`、`prowk/mooncql/protocol` 和 `prowk/mooncql/types`：

```moonbit
async fn main {
  @client.with_connection(
    config=@client.Config::new(compression=true),
    connection => {
      let statement = connection.prepare(
        "SELECT id, message FROM events WHERE device=?",
        keyspace="app",
      )
      let pages = statement.pages(
        [Integer(42)],
        options=@protocol.QueryOptions::new(page_size=100, skip_metadata=true),
      )
      while pages.next() is Some(page) {
        for i = 0; i < page.rows.length(); i = i + 1 {
          // 按应用需要匹配 Text、Null 等值类型。
          ignore(page.get(i, "message"))
        }
      }
    },
  )
}
```

普通查询可通过 `QueryOptions::new(keyspace="app")` 指定 keyspace。命名绑定使用 `values=[...]` 与 `value_names=[...]`，二者顺序对应；预处理语句使用位置绑定。批处理由 `connection.batch([Query(cql, values), statement.bind_batch(values)], kind=Unlogged, options=...)` 构造，默认类型为 Logged。

`Duration(months, days, nanoseconds)` 的前两项为 Int，最后一项为 Int64，所有非零分量须同号。decimal 表示为 `Decimal(scale, signed_big_endian_bytes)`，varint 同样保留二进制有符号整数；set／map 使用数组表示，不保证元素顺序。

推荐使用 `with_connection` 管理关闭和收发任务；`with_serial_connection` 将在途额度固定为 1，并使用相同的收发逻辑。main 分支的 `connect(group, config~)` 要求传入调用方任务组，退出该组会回收后台任务；该签名变更尚未发布到 0.1.0。Prepared／Pager 在所属连接存活期间有效。共享连接推荐使用完整限定表名或显式 keyspace，避免并发 `USE` 改变连接级上下文。

main 分支支持连接、排队、执行超时和逻辑操作总截止时间，`TimedOut` 会保留阶段与可能发送状态，详见[超时与取消](docs/timeouts.md)。

main 分支另提供等待数量、等待字节、在途数量和在途字节上限，支持满载时等待或拒绝，以及服务端 `THROW_ON_OVERLOAD`，详见[背压与过载](docs/backpressure.md)。

main 分支支持 TCP／TLS 共用传输、自定义 CA、名称校验和显式客户端证书，已通过 Windows／Linux 及认证／压缩矩阵，见 [TLS 连接](docs/tls.md)。

main 分支提供作用域 Session，每节点独立连接并以有上限的退避和抖动恢复，健康节点间轮询调度；默认不重放已失败请求，显式幂等声明可启用[有界重试](docs/retries.md)。支持同一 SessionPrepared 对象跨节点及连接更换，见 [Session 与恢复](docs/session.md)。

main 分支的预处理缓存支持可配置 LRU 和按 CQL/keyspace 合并并发准备，淘汰不影响已返回对象，见[预处理缓存](docs/prepared-cache.md)。

`skip_metadata=true` 适用于已有元数据的 Prepared／Pager；低层普通请求省略元数据时，需通过 `request(..., cached=columns)` 或 `run(..., cached=columns)` 提供匹配的列定义。

## 失败语义与边界

main 分支中，等待名额或写锁时取消只移除该请求；完整发送后取消或超时会保留 stream 和在途额度，并吸收迟到响应。`max_abandoned`（默认 64）与 `abandoned_timeout_ms`（默认 30000）限制废弃请求，超限关闭连接，设数量为 0 可立即关闭。部分发送、EOF、损坏帧或非法长度仍关闭整条连接，使其他在途请求明确失败。连接失效后由应用重新调用 `with_connection`；普通写请求不会自动重放，取消也不表示数据库未执行该请求。已发布的 0.1.0 仍采用取消或超时即关闭的规则。

只有服务端返回匹配语句 ID 的 UNPREPARED 时，Prepared.execute 才重新 PREPARE 并重试一次。BATCH 不自动重放；其中的预处理语句失效时，由调用方处理服务端错误。其他服务端错误通过 `@client.Server(error)` 返回，正常业务错误不会关闭连接。低层 `request` 返回 Reply，可读取 warnings 等附加信息。

外层帧的载荷上限为 131071 字节；更大的消息拆分为连续分片。默认消息正文上限为 16 MiB，由 `Config.max_frame_bytes` 控制，适用于收发及重组；最大在途请求数默认为 128。类型和值递归最多 32 层，每个 Pager 仅允许一个活动的 `next` 调用。

## 验证

主线新增的条件写入 API 见[条件写入说明](docs/conditional-writes.md)，尚未包含在 Mooncakes 0.1.0 中。固定 Cassandra 5.0.5 提交的协议回归依据见[协议清单](docs/protocol-v5-regression.md)。

单元和本地 TCP 模拟测试无需 Cassandra：

```sh
moon check --target native --deny-warn
moon test --target native --deny-warn
moon info
moon fmt --check
```

覆盖固定协议字节、CRC 损坏和截断、LZ4 长度及偏移边界、消息头各位置分割、反序响应、挂起读取取消、背压、认证切帧、并发元数据缓存、预处理失效恢复及分页。duration 固定字节由独立 Python 驱动生成。

真实数据库集成入口会创建或清空专用的 `mooncql_test` 表，包括 events、v5_values、v5_counters 和 v5_metadata：

```sh
moon run cmd/integration
python -m pip install -r scripts/requirements-reference.txt
python scripts/interop.py
```

默认并发写入 10,000 条事件，逐页核对全部字段、更新和删除；`CQL_ROWS` 可设为 1–100000。专项验收包括 400000 字节双向传输、duration、三种批处理、命名绑定、请求级 keyspace、TTL 时间覆盖、schema 变化及结果元数据 ID 通知。服务端客户端视图用于核对 MoonBit 实际使用协议 5。

参考驱动固定使用正式 v5；先独立核对全部 MoonBit 数据，再写入不同 CQL 类型，由 MoonBit 核对和回写，最后由 Python 确认。设置 `CQL_ASSERT_V5_ONLY=1` 额外确认服务器拒绝旧协议。CI 在 Linux／Windows 上运行单元测试，并对无认证／密码认证、普通帧／LZ4 四种组合运行上述数据库与互操作验收。

结束 Docker 环境：`docker compose down`。测试数据、临时运行时和本地日志不纳入版本控制。

## 参考与许可

- [Apache CQL binary protocol v5](https://github.com/apache/cassandra/blob/cassandra-5.0/doc/native_protocol_v5.spec)
- [Apache Cassandra framing](https://github.com/apache/cassandra/tree/cassandra-5.0/src/java/org/apache/cassandra/net)
- [LZ4 block format](https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md)
- [MoonBit async](https://github.com/moonbitlang/async)

Apache Cassandra 采用 Apache-2.0；本项目参考其公开 v5 规范、帧布局、CRC 参数和服务端握手行为。LZ4 仅作为块格式参考，压缩和解压由 MoonBit 实现，未链接或打包上游 C 实现；上游 `lib` 目录采用 BSD-2-Clause，其余文件的许可见上游说明。

运行时依赖 MoonBit async 0.22.3（Apache-2.0），用于 TCP 与异步任务。[Apache Cassandra Python Driver](https://github.com/apache/cassandra-python-driver) 3.30.0（Apache-2.0）和 [python-lz4](https://github.com/python-lz4/python-lz4) 4.4.5（BSD-3-Clause）仅用于独立互操作、压缩块和 duration 字节样例验证，不作为驱动运行时依赖。

Apache-2.0，见 LICENSE。

main 分支还提供 [REGISTER 与结构化服务端事件](docs/events.md)，使用有界事件队列，与普通请求响应独立分发。

可选的 [控制连接与拓扑发现](docs/topology.md) 从种子节点读取 local／peers_v2，合并事件并定期刷新，支持 native 地址转换和断线后重新订阅。

[DC 与 token-aware 路由](docs/routing.md) 支持显式本地 DC、可选远端回退、Murmur3 和两种常用复制策略。SessionPrepared 自动使用分区键元数据；普通查询可提供 RoutingHint。

通过 [with_info 高层接口](docs/execution-info.md) 读取 tracing、warnings、custom payload、协调节点和尝试次数；可发送请求 tracing 与 payload，并保留重试和重新准备的前次响应信息。

可选 [Metrics 与安全请求监听](docs/metrics.md) 汇总阶段耗时、实时额度、超时／取消、重连、缓存和压缩比例；默认关闭观测，监听器错误被隔离，事件不包含 CQL、绑定值或密码。
