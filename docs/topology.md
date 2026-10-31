# 控制连接与拓扑发现

[文档目录](README.md) · [入门教程](getting-started.md)

0.2.1 新增的成员身份替换保护、DC／rack 变化回归和双 DC 实库入口见[多数据中心与拓扑变化](multidc.md)。

本文适用于 0.2.1 和 0.2.2。给 SessionConfig 传入 `discovery=DiscoveryConfig::new()` 即可从 contact_points 的种子节点读取并发现其他节点；省略 discovery 时继续使用显式节点配置。驱动单独维护一条控制连接，业务请求仍使用每个节点自己的连接。

```moonbit
@client.with_session(
  config=@client.SessionConfig::new(
    contact_points=[@client.Endpoint::new(host="127.0.0.1", port=9042)],
    discovery=@client.DiscoveryConfig::new(),
  ),
  session => {
    ignore(session.query("SELECT release_version FROM system.local"))
    ignore(session.topology())
  },
)
```

控制连接先 REGISTER 三类事件，再读取 `system.local` 和 `system.peers_v2`。快照包含 host_id、广播的 native IP / 端口、可连接 Endpoint、数据中心、rack、tokens、schema_version，以及集群名称和 partitioner。仅完整且通过校验的快照会更新成员：重复 host_id、无效 UUID / 地址 / 端口、缺失或无效 token、超过数量限制、重复映射目标或集群名称变化均保留上一份快照并记录错误。对系统表的读取共用一个操作截止时间，peers_v2 分页读取，避免单页截断被当成完整成员列表。

节点移除时先关闭其连接、取消并等待维护任务，再移除成员；新增节点启动有界退避的独立连接维护。控制连接断开后换用已知节点或初始种子，重新订阅并刷新。`session.close()` 同时结束控制连接、节点连接及其后台任务。SessionPrepared 在访问新成员时清理已移除节点的准备状态。

事件只触发重新读取，驱动不会把可能乱序的 DOWN / UP 通知直接当作最终成员状态。单个控制任务以 debounce_ms（默认 100 毫秒）合并突发通知；没有为每个事件创建任务。refresh_interval_ms 默认 30000 毫秒，定期完整刷新补偿遗漏通知和满载队列丢失。max_nodes 默认 1024，max_tokens_per_node 默认 4096，均可配置，范围为 1–65536。控制连接恢复使用 Session 的有上限退避和抖动；快速反复断开不会因刚建立过连接就重置退避。

`session.topology()` 返回复制的快照，修改公开节点或 token 数组不会污染内部状态。`control_status()` 提供 connected、实际连接 Endpoint、generation、refreshes、stale 和 last_error。stale 表示事件提示元数据失效、控制连接断开或上次刷新失败；旧快照保留以供诊断，不代表节点当前健康。节点的实际连接状态仍通过 nodes() 读取。

广播地址通过 `DiscoveryConfig::new(address_mapper=native => Some(Endpoint::new(...)))` 转换。默认按 native 地址连接，支持 IPv4 / IPv6；返回 None 可排除某个节点，返回的 Endpoint 可指定 TLS server_name。多个节点不能映射到同一个地址和端口。local 的 rpc_address 为通配地址时沿用实际种子连接端点。NAT / 端口映射环境应明确提供映射，避免将集群内部地址当成宿主机地址。

系统表字段以 [固定 Cassandra 5.0.5 SystemKeyspace.java](https://github.com/apache/cassandra/blob/c8abc9f3e1bb46bc4d699c3a167e43df62b9bec8/src/java/org/apache/cassandra/db/SystemKeyspace.java) 为准：local 使用 rpc_address / rpc_port，peers_v2 使用 native_address / native_port。

模拟回归覆盖 1000 个事件合并、遗漏事件、错误快照保留、成员移除与恢复、地址映射、快照隔离和重新订阅。单节点真实集成也校验了标识、端口、数据中心和 token。复制策略和 token-aware 调度见[路由文档](routing.md)。专用三节点验收命令如下：

```sh
python -m pip install -r scripts/requirements-reference.txt
docker compose -f compose.cluster.yaml up -d --wait --wait-timeout 360
CQL_USERNAME=cassandra CQL_PASSWORD=cassandra CQL_COMPRESSION=lz4 python scripts/discovery_recovery.py --docker-compose
docker compose -f compose.cluster.yaml down --volumes
```

Compose 需使用 PasswordAuthenticator；可先按 CI 环境设置 CQL_AUTHENTICATOR=PasswordAuthenticator。脚本仅操作专用集群，自动把容器 native 地址映射到宿主机三个端口，从一个 seed 发现三个节点，逐节点读取 local 核对 host_id / DC / rack / tokens，再实际停掉控制连接所属节点，验证换节点重新订阅和业务查询，恢复节点后检查关闭状态。为支持认证节点故障，会将该测试集群 system_auth 调整为 dc1 的 RF=3 并修复。诊断保存在忽略的 .artifacts；测试结束时三个节点均恢复运行。
