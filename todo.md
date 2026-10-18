- [x] 建立与 Cassandra 5.0.5 对齐的协议回归清单，固定参考源码提交，核对握手切帧、CRC、LZ4 原始载荷和消息扩展字段。验收：保存可复现的字节样例与来源；压缩协商后的原始载荷以 `uncompressedLength == 0` 识别；握手前后 OPTIONS、分片边界和扩展字段均有回归用例。参考：[v5 规范](https://github.com/apache/cassandra/blob/cassandra-5.0/doc/native_protocol_v5.spec)、[FrameDecoderLZ4.java](https://github.com/apache/cassandra/blob/cassandra-5.0/src/java/org/apache/cassandra/net/FrameDecoderLZ4.java)。

- [x] 补充 LWT 条件写入接口与元数据回归测试。验收：真实 Cassandra 上覆盖 `IF NOT EXISTS`、`IF 条件` 的成功与失败，正确读取 `[applied]` 及返回列；开启 `skip_metadata` 后仍使用本次 LWT 返回的元数据，不将其错误缓存为后续普通结果元数据；覆盖 SERIAL／LOCAL_SERIAL。参考：[ExecuteMessage.java](https://github.com/apache/cassandra/blob/cassandra-5.0/src/java/org/apache/cassandra/transport/messages/ExecuteMessage.java)。

- [x] 区分请求等待名额、等待写锁、部分发送、完整发送和收到响应的状态，细化取消处理。验收：未发送请求取消不影响其他请求；完整发送后取消的请求保留 stream 占用并吸收迟到响应，配置废弃请求数量与存活时间上限，超限时关闭连接；部分发送或协议状态损坏时关闭连接；乱序与迟到响应不会串请求，取消不被解释为服务端撤销执行。

- [x] 增加连接超时、排队超时、请求执行超时和逻辑操作总截止时间。验收：串行与多路复用接口的计时范围一致；等待锁、重新 PREPARE、重试均受总截止时间约束；超时错误能够区分失败阶段及请求是否可能已发送。

- [x] 增加有界等待队列和在途字节预算，并提供 `THROW_ON_OVERLOAD` 启动选项。验收：达到数量或字节上限时按配置等待或明确拒绝；成功、异常、取消均归还额度；编码缓冲不因排队请求数无限增长；模拟过载测试覆盖服务端背压与 OVERLOADED 响应，不自动重放结果未知的写入。参考：[StartupMessage.java](https://github.com/apache/cassandra/blob/cassandra-5.0/src/java/org/apache/cassandra/transport/messages/StartupMessage.java)。

- [x] 抽象 TCP／TLS 共用的传输接口，使用成熟 TLS 实现接入证书验证。验收：支持自定义 CA、主机名验证和可选客户端证书；有效证书连接成功，错误主机名、过期证书及不可信证书连接失败；TLS 下认证、LZ4、大消息和取消测试通过。

- [x] 增加作用域管理的 Session，先实现单节点连接维护与自动恢复。验收：节点重启后业务无需重建 Session 即可提交新请求；采用有上限的退避与随机抖动；关闭 Session 后所有连接、恢复任务和等待请求结束；恢复连接不隐式重放断线前的请求。

- [x] 将 Session 级预处理语句与具体 Connection 解耦，维护节点和连接代次对应的准备状态。验收：连接替换后原业务预处理对象仍可使用；保留 CQL、keyspace 与参数快照；节点返回匹配 ID 的 UNPREPARED 时最多恢复一次；不同节点的结果元数据不会相互覆盖。

- [x] 将固定 64 条预处理缓存改为容量可配置的 LRU，并按语句合并并发 PREPARE。验收：相同 CQL 与 keyspace 的并发准备只发出一次请求；不同语句不被同一全局准备锁串行阻塞；淘汰不破坏已返回对象；准备失败能够清理合并状态并允许后续重试。

- [x] 增加显式幂等声明及有界重试策略，保留默认不重放结果未知写入的行为。验收：只有符合错误类型与幂等策略的请求可以重试；所有尝试共享截止时间与次数预算；counter、LWT、集合追加和 BATCH 的故障用例不会因默认策略重复执行；错误保留各次尝试的节点与原因。

- [x] 为 Session 增加显式多节点配置、每节点连接管理、健康状态和请求调度。验收：三节点环境关闭任一节点后，在满足副本和一致性要求时新请求可通过健康节点完成；节点恢复后重新参与调度；所有节点不可用时在截止时间内明确失败；单节点故障不关闭其他节点连接。

- [x] 实现 REGISTER 与结构化 TOPOLOGY_CHANGE、STATUS_CHANGE、SCHEMA_CHANGE 事件解码。验收：覆盖节点新增／移除／移动、UP／DOWN，以及 keyspace、table、type、function、aggregate 的 schema 事件；正确读取 IPv4／IPv6 和端口；仅合法 EVENT 使用服务端事件分发路径，事件与普通响应交错不会影响 stream 关联。参考：[Event.java](https://github.com/apache/cassandra/blob/cassandra-5.0/src/java/org/apache/cassandra/transport/Event.java)。

- [x] 实现控制连接、拓扑快照刷新和事件订阅恢复。验收：读取并核对 `system.local`、`system.peers_v2` 的节点标识、native 地址、数据中心和 token；控制连接断开后重新订阅并刷新快照；重复、乱序或遗漏事件最终收敛；支持广播地址到可连接地址的转换；事件突发不会触发无界刷新任务。

- [x] 增加数据中心感知与 token-aware 路由，明确支持的 partitioner 和复制策略。验收：单字段及组合分区键 routing key、Murmur3 token 与独立实现一致；副本选择与真实集群一致；优先使用本地数据中心的合适节点；缺少分区键、元数据过期或不支持的策略能安全回退；跨数据中心回退必须显式配置。

- [ ] 提供请求 tracing 开关和 custom payload 发送能力，并在高层查询、预处理、批处理与分页接口保留执行信息。验收：请求 flags 与附加字段编码通过独立字节验证；真实 tracing 请求返回可查询的 tracing ID；warnings、custom payload、协调节点与尝试次数不会被高层接口丢弃；默认 QueryHandler 忽略请求 custom payload 不被误判为驱动失败。

- [ ] 增加轻量指标与请求监听接口。验收：能够观测排队时间、执行耗时、在途数量与字节数、超时、取消、重连、缓存命中及压缩比例；监听器异常不破坏收发任务；默认不记录密码或绑定值；关闭监听时测量额外开销。

- [ ] 增加 Row 类型化读取和常用值转换接口。验收：列不存在、NULL、类型不匹配具有不同错误；错误包含列名和期望类型；UUID、日期时间、decimal、varint 转换不损失精度；重复读取列名不反复线性扫描全部列；保留底层 Value 访问能力。

- [ ] 增加可恢复分页游标与明确的分页失败语义。验收：游标关联 CQL、keyspace、绑定值及必要执行选项，拒绝不匹配的恢复请求；失败不提前推进游标；保持空页续读和单次 next 限制；连接恢复后的分页与独立驱动核对，并明确分页不保证跨页快照一致性。

- [ ] 增加确定性随机生成、差分互操作和协议状态机测试。验收：固定种子复现类型嵌套、LZ4 数据、随机拆包、乱序响应、取消与断线组合；与独立实现双向核对；异常输入不会导致崩溃、无限等待或无界分配；失败样例缩减后纳入回归测试。

- [ ] 扩展集成验收矩阵与长期运行测试。验收：在现有认证／压缩四种组合之外加入 TLS、LWT、三节点故障、控制连接恢复和 schema 变化；至少完成一次连续 6 小时混合读写与周期故障测试；停止负载后 pending、等待队列和后台任务回落，缓存不超过上限，内存不存在随请求总数持续增长的趋势；仅对实测服务端版本声明兼容。

- [ ] 建立可复现性能基准，再优化经测量确认的压缩、复制和发送热点。验收：覆盖并发数 1／32／128、小消息／400000 字节消息、可压缩／不可压缩数据及多种分页大小；记录吞吐、P50／P95／P99、CPU 与峰值内存；区分纯编解码和真实数据库结果；优化前后使用相同环境与正确性校验，未达到可测收益的优化不合入。

- [ ] 增加持续事件写入、分页查询和主动节点故障的完整示例，并同步 README、API 文档及申报书。验收：按文档可启动专用集群并复现节点故障与恢复；示例展示延迟、失败原因和恢复过程；说明 BATCH 的适用边界、重试与分页语义；新增 API 有可运行示例，公开接口、版本声明与实测能力一致。
