# 多数据中心与拓扑变化

[文档目录](README.md) · [路由](routing.md) · [拓扑发现](topology.md) · [连接池](pooling.md)

本页新增的成员身份检查和验收入口适用于**0.2.1**。稳定版 0.2.0 的基本发现与 DC 配置见[拓扑发现](topology.md)和[路由](routing.md)。

## 成员与路由语义

`RoutingConfig::new("dc1")` 只向当前健康的本地 DC 数据连接分配业务请求。设置 `allow_remote=true` 后才允许远端候选；本地健康候选仍优先。控制连接可以从任一已知成员读取拓扑，即使业务请求禁止远端回退。

选择远端协调节点不会修改请求的一致性。例如 `LOCAL_QUORUM` 仍发送 `LOCAL_QUORUM`，其本地含义由协调节点所在 DC 和 Cassandra 的复制策略决定。业务是否允许这种变化须由应用明确选择。

完整快照按 `host_id` 识别成员。地址变化会关闭旧地址的整个池；同地址出现不同 `host_id` 时也会重建池，物理预处理 ID 不会沿用。初始 seed 在第一次完整快照中绑定身份。控制连接观察到自己的 `host_id` 改变时重新握手和订阅。DC、rack、tokens 和 keyspace 复制策略一起更新；仅这些元数据变化不会重建仍属于同一成员的连接。

事件触发完整刷新，重复／乱序事件合并，遗漏事件由周期快照补偿。事件、周期刷新进行中、刷新失败、连接断开或快照超过 `max_metadata_age_ms` 时停止使用旧 token／复制因子进行副本偏好。已有 DC 信息继续约束候选；旧快照保留用于诊断，不能当作当前副本列表。

## 确定性回归

```sh
moon test client/topology_changes_test.mbt client/topology_test.mbt client/routing_test.mbt --target native --deny-warn
```

TCP 模拟覆盖新增／移除、1000 个重复事件、遗漏通知后的周期收敛、地址迁移、数据和控制节点同地址替换、准备 ID 隔离、token 重分布、DC／rack 变化、复制因子调整和阻塞刷新。另对本地 DC 断线分别验证禁止／允许远端回退，并直接检查 `LOCAL_QUORUM` 的线协议值。

## 可选双 DC 短时实库验收

需要 Docker Compose、MoonBit 原生工具链和 Python 3.11。专用集群使用 dc1 一个节点、dc2 两个节点，Cassandra 5.0.5、Native Protocol v5 + LZ4、无认证，512 MiB JVM 堆／节点、`ActiveProcessorCount=2`。入口创建专用 `mooncql_multidc` keyspace，停止并恢复 dc1 节点。宿主机还需容纳 JVM 非堆、缓存、容器和磁盘，不能把总堆大小当作最低内存。

先停止使用宿主机端口 19052–19054 的其他测试集群，清除环境中的 `CQL_USERNAME`、`CQL_PASSWORD` 和自定义 `CQL_CLUSTER_PORTS`，再运行：

```sh
python -m pip install -r scripts/requirements-reference.txt
docker compose -f compose.cluster.yaml -f compose.multidc.yaml up -d --wait --wait-timeout 360
python scripts/multidc_acceptance.py --docker-compose
docker compose -f compose.cluster.yaml -f compose.multidc.yaml down --volumes
```

脚本从一个 seed 发现两个 DC，调整 NTS 的 dc2 复制因子从 1 到 2，等待两个 Session 的快照更新及 schema agreement，并把 64 个分区键的 token／副本集合与独立 Python Driver 核对。随后停止 dc1：禁止回退的 Session 在本地等待并超时；允许回退的 Session 在 dc2 使用原样的 `LOCAL_QUORUM` 完成读写。恢复 dc1 后重新选择本地节点，并断言排空后任务与额度归零。

脚本回收客户端进程，并恢复自己停止的节点；使用者仍需运行最后的 Compose 清理命令。机器可读结果、逐键比对和日志保存在忽略的 `.artifacts/multidc-*`，CI 作为附件归档。实库入口验证实际 DC 故障与恢复；成员地址／身份替换、事件排列和阻塞刷新由确定性测试覆盖。它不替代六小时长测。
