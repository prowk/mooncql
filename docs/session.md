# Session 与连接恢复

本文描述 main 分支；Session 尚未发布到 0.1.0。默认维护单个节点，也支持显式配置多个协调节点。

```moonbit
@client.with_session(
  config=@client.SessionConfig::new(
    connection=@client.Config::new(host="127.0.0.1", port=9042),
  ),
  session => {
    ignore(session.query("SELECT release_version FROM system.local"))
  },
)
```

`with_session` 立即启动连接维护。首次连接未完成或节点重启时，查询在有界队列中等待可用连接；等待受同一次操作的 Deadline 约束，超时报 WaitingConnection 阶段，且尚未发送应用请求。数量与字节上限沿用 connection 配置中的 max_waiting／max_waiting_bytes。默认每次调用只尝试一次；显式声明幂等后可启用有界重试，见[重试语义](retries.md)。

恢复采用指数退避，默认从 25 毫秒增长至最多 2000 毫秒，并加入 ±20% 随机抖动，最终延迟仍不超过上限。连接稳定 1000 毫秒后重置退避；短暂建立后立即断开的连接继续增加退避，避免频繁重连。参数可通过 SessionConfig 配置。

`status()` 返回整体可用状态、累计建立连接次数和累计连接尝试次数。`nodes()` 返回每个 Endpoint 的 Connecting／Ready／Backoff／Stopped、独立连接代次及最近错误。`last_error()` 可读取最近的连接错误，驱动不会自动记录凭据或绑定值。`waiting_count()` 与 `active_count()` 可用于验收。

`await session.close()` 的 MoonBit 写法是 `session.close()`：该异步方法会停止重连、关闭连接、唤醒等待请求，并等待维护任务及活动调用结束。退出 `with_session` 的作用域也会取消并等待所有后台任务。Session 不能在作用域结束后继续使用。

Session 提供 request／query／prepare 接口。`session.prepare(cql, keyspace=...)` 返回 SessionPrepared，保存原始 CQL 与 keyspace；执行时按节点地址与连接代次查找准备状态，连接替换后原对象仍可使用。绑定值和选项在等待连接前冻结，重新 PREPARE 与匹配 ID 的一次 UNPREPARED 恢复共用原截止时间。每个节点的结果元数据由该连接自己的 Prepared 管理。

Connection 级 Prepared／Pager 仍属于其原连接；可恢复分页尚未实现。推荐显式 keyspace 或完整限定表名，不依赖跨连接保留 USE 状态。模拟回归使用两个节点返回不同结果列和元数据 ID，并在其中一个节点改变元数据，核对另一个节点的 ID 和列定义始终不受影响。

多节点可通过 `SessionConfig::new(contact_points=[Endpoint::new(host=..., port=...), ...])` 配置。认证、TLS、压缩及额度继承 connection 配置，Endpoint 的 server_name 可覆盖该节点的 TLS 校验名称。每个节点独立恢复；轮询只选择已有健康连接的节点，单节点故障不会关闭其他节点连接。所有节点不可用时进入有界等待，受同一操作截止时间限制。每连接的在途预算分别计算，Session 无健康连接时的等待预算沿用 connection 配置。

可通过 discovery 开启[控制连接与拓扑发现](topology.md)，自动维护完整成员快照。默认业务调度依据连接健康状态轮询；传入 RoutingConfig 可开启[数据中心与 token-aware 路由](routing.md)。

模拟回归覆盖收到写入后断连且不重放、恢复后新请求、停在 OPTIONS 时关闭 Session、队列上限、不可用节点的总截止时间、退避限速和作用域退出后的资源回收。

真实重启验收在专用 Compose 环境运行：

```sh
docker compose up -d --wait --wait-timeout 360
python scripts/session_recovery.py --docker-compose
```

该命令会停止并重新启动本仓库 Compose 配置中的 Cassandra 服务。测试保持同一个 Session，在服务恢复后再次查询，最后要求连接代次增加、活动／等待请求均为 0。控制文件和诊断保存在忽略的 `.artifacts/`。本地也已在 Cassandra 5.0.5、PasswordAuthenticator 与 LZ4 下实际停止进程并重启验证，原 Session 恢复至第 2 代连接。

三节点验收使用单独的 Compose 项目：

```sh
docker compose -f compose.cluster.yaml up -d --wait --wait-timeout 360
python scripts/cluster_failover.py --docker-compose
docker compose -f compose.cluster.yaml down --volumes
```

脚本操作专用的三个节点，创建或清空 `mooncql_cluster_probe.items`，使用 dc1 的 RF=3；初始数据以 ALL 写入，逐个停掉任一节点后以 QUORUM 读写并核对 88 条最终记录，再验证恢复加入、其他节点连接代次不变，以及全部不可用的截止时间和关闭。启用密码认证时，先将专用集群的 system_auth 调整为 RF=3 并修复数据，避免认证数据本身缺少副本影响故障验证。脚本结束时三个测试节点均已停止。
