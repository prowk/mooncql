# 数据中心与 token-aware 路由

[文档目录](README.md) · [入门教程](getting-started.md)

本文适用于 0.2.1 和 0.2.2。SessionConfig 的 `routing=RoutingConfig::new("dc1")` 开启本地数据中心优先，且要求同时配置 discovery。local_dc 必须明确给出；默认不会使用远端或 DC 未知的节点。只有设置 allow_remote=true，才允许在本地候选不可用或已尝试后向其他 DC 回退。

```moonbit
@client.with_session(
  config=@client.SessionConfig::new(
    contact_points=[@client.Endpoint::new(host="127.0.0.1", port=9042)],
    discovery=@client.DiscoveryConfig::new(),
    routing=@client.RoutingConfig::new("dc1"),
  ),
  session => {
    let statement = session.prepare("SELECT value FROM app.items WHERE id=?")
    ignore(statement.execute([Integer(7)]))
  },
)
```

SessionPrepared 根据 PREPARE 的 partition_key_indices、对应参数类型和 keyspace 自动构造 routing key。单字段使用字段编码；组合分区键按各字段两字节长度、字段字节和零分隔符组合，顺序依据服务端索引。缺少完整分区键、NULL / UNSET、非法或重复索引、编码超过分区键长度限制时不推断 token。业务参数在异步等待前冻结，路由与执行使用相同快照。

普通 QUERY / 低层 request 可传 `routing=RoutingHint::new("app", key)`。key 是原始 routing key，调用方需保证其与 CQL、keyspace 和绑定值一致。该提示只选择协调节点，不改变请求内容或一致性等级。公开 routing 包提供 routing_key、murmur3_token、Ring 与复制策略解析；query_plan(hint=...) 返回当前健康候选次序，不发送请求。

支持 Cassandra 的 Murmur3Partitioner、SimpleStrategy 和完整副本的 NetworkTopologyStrategy。Murmur3 按 Cassandra 5.0.5 的有符号尾部处理高位字节；非空键的 MIN_LONG hash 规范化为 MAX_LONG，空键返回 MIN_LONG。副本计算按有序 token 环回绕，vnode 不重复计入节点；NTS 遵守 DC、rack 和有效副本数，RF 超过实际节点数时取实际节点数。临时副本（如 3/1）、未知 partitioner / 复制策略、冲突 token 环或缺失 keyspace 元数据均退回普通 DC 策略。

同一 DC 内，副本优先于其他节点；本地普通节点优先于远端副本。同一层按轮询公平选择。显式幂等重试先使用尚未尝试的候选，再考虑重复节点；max_attempts 和 Deadline 仍约束整个逻辑调用。未开启 routing 时保留健康节点间的普通轮询。

控制连接同时分页读取 system_schema.keyspaces 的复制策略，max_keyspaces 默认 4096，允许 1–65536。快照对外复制复制策略中的 Map。事件提示、控制断线或刷新失败会使 token 元数据失效；超过 max_metadata_age_ms（默认 60000 毫秒）也不再使用副本偏好。定期读取期间，尚未过期且没有失效提示的旧快照仍可使用，完整新快照校验后原子替换。回退仍遵守明确的本地 DC 限制；尚未获得 DC 元数据且不允许远端时，请求等待并受原截止时间约束。

参考固定源码为 [Murmur3Partitioner](https://github.com/apache/cassandra/blob/c8abc9f3e1bb46bc4d699c3a167e43df62b9bec8/src/java/org/apache/cassandra/dht/Murmur3Partitioner.java)、[MurmurHash](https://github.com/apache/cassandra/blob/c8abc9f3e1bb46bc4d699c3a167e43df62b9bec8/src/java/org/apache/cassandra/utils/MurmurHash.java)、[SimpleStrategy](https://github.com/apache/cassandra/blob/c8abc9f3e1bb46bc4d699c3a167e43df62b9bec8/src/java/org/apache/cassandra/locator/SimpleStrategy.java) 和 [NetworkTopologyStrategy](https://github.com/apache/cassandra/blob/c8abc9f3e1bb46bc4d699c3a167e43df62b9bec8/src/java/org/apache/cassandra/locator/NetworkTopologyStrategy.java)，哈希均在固定参考清单中。

[固定样例](../fixtures/routing.json) 由 cassandra-driver 3.30.0 独立生成，覆盖单字段 / 组合键、高位字节、不同消息长度、跨 DC / rack、vnode、环边界和较大 RF。复现：

```sh
python -m pip install -r scripts/requirements-reference.txt
python scripts/routing_reference.py
moon test --target native --deny-warn
```

专用三节点脚本 `scripts/discovery_recovery.py --docker-compose` 还创建 mooncql_routing_simple（RF=1）与 mooncql_routing_nts（dc1 RF=2）及各自 probe 表，以 QUORUM 写后读检查 64 个服务端 token 值，核对实际协调节点，并与独立驱动计算的实际副本集合逐项比较。随后仍执行控制节点停止 / 恢复验收。容器映射配置与运行命令见[拓扑文档](topology.md)。这些是专用测试 keyspace，兼容声明仍仅限实际验证的 Cassandra 5.0.5。
