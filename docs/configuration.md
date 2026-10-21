# 连接配置

[文档目录](README.md) · [入门教程](getting-started.md)

`Config` 描述一条物理连接；`SessionConfig` 负责节点、发现、路由和恢复。应用通常在一个长生命周期的 `with_session` 作用域中复用 Session。

```moonbit
let config = @client.SessionConfig::new(
  connection=@client.Config::new(
    host="127.0.0.1",
    port=9042,
    username="app_user",
    password="read_from_your_secret_store",
    compression=true,
    timeout_ms=10000,
    heartbeat_interval_ms=30000,
    heartbeat_timeout_ms=5000,
  ),
)
```

用户名和密码须一起提供；不需要认证时同时省略。真实凭据应来自应用环境或密钥管理系统，不写入源码或日志。

| 配置 | 默认值 | 用途 |
| --- | --- | --- |
| host、port | 127.0.0.1、9042 | 初始连接地址 |
| compression | false | 协商 LZ4 |
| timeout_ms | 10000 | 请求执行期限，毫秒 |
| connect_timeout_ms | 继承 timeout_ms | DNS、TCP、TLS、握手和认证 |
| queue_timeout_ms | 继承 timeout_ms | 等待额度和发送锁 |
| operation_timeout_ms | 继承 timeout_ms | 整次逻辑操作，含恢复和重试 |
| heartbeat_interval_ms | 30000 | 空闲心跳间隔，0 表示关闭 |
| heartbeat_timeout_ms | 5000 | 一次心跳的总预算 |
| max_in_flight | 128 | 每连接并发上限 |
| max_in_flight_bytes | 67108864 | 在途未压缩 envelope 字节 |
| max_waiting、max_waiting_bytes | 64、67108864 | 等待上限 |
| max_frame_bytes | 16777216 | 单消息正文上限 |
| prepared_cache_capacity | 64 | 每连接准备缓存容量 |
| max_abandoned、abandoned_timeout_ms | 64、30000 | 迟到响应占用的回收边界 |

更大的消息仍会按 v5 外层帧上限分片。额度是逻辑请求字节预算，不是进程内存上限。

TLS 通过 `tls=TlsConfig::new(server_name="db.example", ca_file="ca.pem")` 开启，始终进行证书与名称验证。自定义 CA、完整中间证书链以及平台对应的客户端身份见 [TLS](tls.md)。

多节点使用 `contact_points=[Endpoint::new(...), ...]`；自动发现另外设置 `discovery=DiscoveryConfig::new()`。启用路由时设置 `routing=RoutingConfig::new("dc1")`，并明确本地 DC。跨 DC 回退默认关闭。详见 [Session](session.md)、[拓扑](topology.md)与[路由](routing.md)。

请求 keyspace 应通过 QueryOptions 或 prepare 的 keyspace 参数显式设置，或使用完整限定表名。不要依赖跨连接保留 USE 状态。`timestamp` 是微秒写入版本时间，允许除 Int64 最小值外的负值，与 Cassandra 5.0.5 的实际 QueryOptions 解码一致。
