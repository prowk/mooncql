# mooncql

MoonBit 原生实现的 **Cassandra Native Protocol v5 异步驱动**，面向 native 后端。协议编解码、CRC、LZ4 块压缩、分页和请求调度由 MoonBit 实现，TCP 使用 moonbitlang/async；TLS 使用成熟的 OpenSSL／Windows Schannel 实现。

首版锁定正式 v5 协议（0x05／0x85）。已实测 Cassandra 5.0.5；其他 Cassandra 版本和 ScyllaDB 尚未实测。

## 版本与使用方式

| 版本 | 状态 | 范围 |
| --- | --- | --- |
| [0.1.0](https://github.com/prowk/mooncql/releases/tag/v0.1.0) | 已发布到 GitHub 与 [Mooncakes](https://mooncakes.io/docs/prowk/mooncql) | 单协调节点、QUERY／PREPARE／EXECUTE／BATCH、v5 帧、LZ4、认证、基础分页与类型 |
| main 0.2.0-dev | 尚未发布 | 本文新增的 Session、TLS、发现与路由、重试、观测、Row 和游标接口 |

安装已发布版本：`moon add prowk/mooncql@0.1.0`。该包不包含 main 的新增 API，使用时参照 [v0.1.0 文档](https://github.com/prowk/mooncql/blob/v0.1.0/README.md)。体验下列功能需使用 main 源码；模块元数据与 STARTUP 上报版本均为 0.2.0-dev，既有发布保持 0.1.0。

工具链为 moonc 0.10.14+7d59c7ec9、moon 0.1.20260920、moonbitlang/async 0.22.3，默认目标为 native。

## 快速运行

在源码目录安装依赖并启动专用单节点 Cassandra：

```sh
moon update
docker compose up -d --wait --wait-timeout 360
moon run cmd/main
```

默认连接 127.0.0.1:9042。示例和验收入口接受 CQL_HOST、CQL_PORT、CQL_USERNAME、CQL_PASSWORD；设置 CQL_COMPRESSION=lz4 开启压缩。PowerShell 示例：

```powershell
$env:CQL_PORT = '9042'
$env:CQL_COMPRESSION = 'lz4'
moon run cmd/main
```

单节点 Compose 默认无认证。需要密码认证时，启动前设置 CQL_AUTHENTICATOR=PasswordAuthenticator，并为客户端设置专用测试账户 cassandra／cassandra；更改已有实例的启动配置需重新启动服务。该环境用于本项目测试，结束后可运行 `docker compose down`。

## 库用法

导入 client、protocol 和 types 包，使用作用域管理连接与后台任务。下面展示 main 的 Session、预处理和类型化分页；app.events 应由应用先建好，表包含 device 分区键、id 和 message 列。

```moonbit
async fn main {
  @client.with_session(
    config=@client.SessionConfig::new(
      connection=@client.Config::new(compression=true),
    ),
    session => {
      let statement = session.prepare(
        "SELECT id, message FROM events WHERE device=?",
        keyspace="app",
      )
      let pages = statement.pages(
        [Integer(42)],
        options=@protocol.QueryOptions::new(
          page_size=100,
          skip_metadata=true,
        ),
      )
      while pages.next() is Some(page) {
        for index in 0..<page.rows.length() {
          let row = page.row(index)
          let id = row.int("id")
          let message = if row.is_null("message") { "" } else { row.text("message") }
          println("\{id}: \{message}")
        }
      }
    },
  )
}
```

普通查询可使用 QueryOptions::new(keyspace="app")；命名绑定的 values 与 value_names 次序对应。预处理使用位置绑定。共享连接推荐显式 keyspace 或完整限定表名，避免并发 USE 改变上下文。

Connection 级 Prepared／Pager 属于其原连接；SessionPrepared 和 Session Pager 可使用恢复后的连接。游标可导出并在匹配上下文的其他连接恢复。低层 connect(group, config~) 需要调用方任务组，with_connection／with_session 会管理关闭和任务回收。

## 能力与说明

| 能力 | 行为与文档 |
| --- | --- |
| 正式 v5 传输 | envelope 与外层帧分层、CRC24／带固定种子的 CRC32、TCP 拆包、乱序响应、大消息分片和 LZ4 原始载荷；[固定协议回归依据](docs/protocol-v5-regression.md) |
| CQL 请求 | 参数化 QUERY、PREPARE／EXECUTE、[BATCH 及其边界](docs/batches.md)、请求级 keyspace、32 位标志、now_in_seconds、一致性和时间戳 |
| 条件写入 | 保留 [applied] 与返回列，SERIAL／LOCAL_SERIAL；[LWT](docs/conditional-writes.md) |
| 生命周期和失败阶段 | 连接／排队／执行超时、总 Deadline、未发送与完整发送后的取消；[超时与取消](docs/timeouts.md) |
| 额度和过载 | 在途数量／字节、等待数量／字节、等待或拒绝、THROW_ON_OVERLOAD；[背压](docs/backpressure.md) |
| 安全连接 | 自定义 CA、主机名验证、可选客户端证书；[TLS](docs/tls.md) |
| Session 与准备缓存 | 独立节点恢复、跨代次预处理、配置化 LRU 与并发准备合并；[Session](docs/session.md)、[缓存](docs/prepared-cache.md) |
| 重试 | 显式幂等声明、次数与截止时间预算、各次失败信息；[重试](docs/retries.md) |
| 服务端事件 | REGISTER、结构化拓扑／状态／schema 事件、有界队列；[事件](docs/events.md) |
| 发现与路由 | 控制连接、local／peers_v2、地址转换、订阅恢复；本地 DC、Murmur3、副本优先与回退；[拓扑](docs/topology.md)、[路由](docs/routing.md) |
| 执行信息 | tracing、custom payload、warnings、协调节点、尝试与准备历史；[with_info](docs/execution-info.md) |
| 观测与资源 | 排队／执行时间、数量／字节、超时／取消、重连、缓存和压缩比例；异常监听器隔离；[Metrics](docs/metrics.md)、[资源快照](docs/session.md) |
| 行与值 | 区分缺列、NULL、类型不符，共享列名索引；精确 UUID／日期时间／decimal／varint；[Row](docs/rows.md) |
| 可恢复分页 | 绑定 CQL、keyspace、参数及必要选项，失败不推进，空页续读与单次 next；[游标](docs/paging.md) |

支持文本、blob、布尔、整数、浮点、UUID／timeuuid、inet、date／time／timestamp、duration，以及 list／set／map、tuple、UDT。bigint／timestamp 使用 Int64；decimal 和 varint 保留任意精度有符号字节及精确文本转换。Value.Empty 与 Null 不同；底层 Value 始终可访问。

## 失败语义与边界

普通写入、LWT、counter、集合追加和 BATCH 默认不自动重放。只有适合的错误和显式幂等策略才启用有界重试。匹配语句 ID 的 UNPREPARED 可重新准备并恢复一次；BATCH 不自动重放。取消或超时不代表服务端撤销执行。

main 中，未发送时取消只移除本请求；完整发送后保留 stream 和额度，吸收迟到响应。max_abandoned（默认 64）和 abandoned_timeout_ms（默认 30000）限制废弃请求，超限关闭连接。部分发送、EOF 或损坏协议状态会使该连接上的在途请求明确失败；Session 随后恢复连接。已发布 0.1.0 采用取消或超时即关闭的旧规则。

外层帧载荷上限为 131071 字节，更大的消息分片。默认消息正文上限 16 MiB，由 Config.max_frame_bytes 控制；默认每连接最多 128 个在途请求。类型和值递归上限为 32，每页 ROWS 最多解码一百万个 Value 节点，含容器及补齐的 NULL。预处理缓存默认 64 条，容量可配置。跨 DC 回退需显式开启；缺少路由信息时安全回退。

每个 Pager 只允许一个活动 next；分页不保证跨页快照。游标关联检查用于防止误用，序列化字节可能包含查询和绑定值，应按业务数据保护。BATCH 用于合适的同分区写入或其明确原子性需求，跨分区大批次不应当作常规吞吐优化。

## 验证与运行示例

无需数据库的单元与本地 TCP 模拟测试：

```sh
moon check --target native --deny-warn
moon test --target native --deny-warn
moon info
moon fmt --check
```

[确定性差分与状态测试](docs/differential-tests.md) 使用固定种子，独立核对嵌套类型与 LZ4 双向互操作，组合随机拆包、响应乱序、取消和半帧 EOF。精确转换样例由 Python int、calendar 和 uuid 独立生成。

真实单节点集成会创建或清空 mooncql_test 中的专用数据：

```sh
moon run cmd/integration
python -m pip install -r scripts/requirements-reference.txt
python scripts/interop.py
```

默认写入并逐页校验 10000 条事件，CQL_ROWS 可设置为 1–100000。覆盖 400000 字节双向传输、LWT、批处理、命名绑定、keyspace、TTL、schema 变化、tracing 和元数据更新。独立 Python 驱动固定使用正式 v5。

| 示例入口 | 用途 |
| --- | --- |
| cmd/main | 单节点事件写入与分页 |
| scripts/session_recovery.py --docker-compose | 保留 Session／预处理／Pager，重启后继续，并与独立驱动核对游标 |
| scripts/discovery_recovery.py --docker-compose | 单种子发现三节点、核对副本与协调节点、控制连接恢复 |
| scripts/cluster_failover.py --docker-compose | 逐节点故障、RF=3／QUORUM、恢复代次及全部不可用期限 |
| [cmd/soak 与 long_run.py](docs/long-run.md) | 持续混合读写、分页、主动故障、延迟与失败原因、资源及内存趋势 |
| [scripts/benchmark.py](docs/performance.md) | 纯 LZ4／编解码和真实数据库的吞吐、P50／P95／P99、CPU、峰值内存 |

CI 在 Windows／Linux 运行单元与 TLS 用例，数据库矩阵覆盖无认证／密码认证和普通帧／LZ4 四种组合，并提供三节点验收。本轮[六分钟混合负载与四轮节点故障](docs/long-run.md)已通过，完整保留 37 条采样；停止后 pending、队列、后台任务和字节额度归零。连续六小时和长期内存趋势验证单列为后续暂缓项，尚未执行。完整 132 场景、792 条性能记录已通过；小块 LZ4 有明确收益，数据库结果不作整体提速声明，见[原始报告与分析](docs/performance.md)。先前小堆实例的超时保留为失败记录，未计作通过。

## 参考与许可

- [Apache CQL binary protocol v5](https://github.com/apache/cassandra/blob/cassandra-5.0/doc/native_protocol_v5.spec)
- [Apache Cassandra framing](https://github.com/apache/cassandra/tree/cassandra-5.0/src/java/org/apache/cassandra/net)
- [LZ4 block format](https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md)
- [MoonBit async](https://github.com/moonbitlang/async)

协议与 CRC 实现参考公开 Cassandra 规范及源码，LZ4 由 MoonBit 实现，未链接上游 C 压缩库。TCP 与 TLS 适配使用 async 0.22.3 及其 Apache-2.0 TLS 实现，保留来源与许可。Cassandra Python Driver 3.30.0 和 python-lz4 4.4.5 仅用于独立测试，不是运行时依赖。

Apache-2.0，见 LICENSE。测试数据、临时运行时、日志和非工程申报材料不纳入公共源码。
