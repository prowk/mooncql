# 性能基准

[文档目录](README.md) · [开发指南](development.md)

`scripts/benchmark.py` 在隔离目录构建指定 Git 基线和当前工作区，以同一入口、工具链和专用数据库比较。数据校验失败立即停止，不将失败计作成功样本。

该入口固定单连接。0.2.1 另有[每节点连接数评估](pooling-evaluation.md)，使用相同数据通道与固定总并发比较 1／2／4 条连接，记录吞吐、尾延迟和客户端资源成本。

```sh
docker compose -f compose.benchmark.yaml up -d --wait --wait-timeout 360
python scripts/benchmark.py --baseline-ref 50fa621 --trials 3 --server-description "记录系统、JRE、堆大小和网络环境"
```

按 compose.benchmark.yaml 设置连接端口及认证环境变量。默认专用端口 19042；脚本创建或覆盖 mooncql_bench.probe 的测试分区。先使用 `--smoke` 检查环境，不能把它算作完整矩阵。

完整矩阵包含 132 个场景：64 和 400000 字节、重复和固定种子随机载荷、普通帧和 LZ4、并发 1、32、128，以及页大小 1、4、8。纯 codec 与纯 LZ4 场景独立于真实数据库读写和分页。

每场景默认三轮，记录吞吐、P50、P95、P99、进程 CPU 与峰值内存。分页同时记录完整查询和单页延迟。峰值内存覆盖整个进程生命周期；吞吐包含入口的正确性校验，不应解释为服务端极限或跨环境可比结果。

基线与当前的顺序由固定种子打乱。结果、工具链、源码及生成 C 摘要保存到本地 `.artifacts/performance-*`，不随源码或运行时包发布。评估优化时应保留全部样本、进行同代码校准并记录环境，不能仅选择有利场景。

0.2 包含按输入规模分配短块 LZ4 哈希表的优化。既有测量支持该局部优化，不据此宣称数据库整体提速。当前发布未重新运行完整性能矩阵，长期内存趋势也未验证。

## 到达率、排队与原始样本

```sh
python scripts/load_benchmark.py --baseline-ref v0.2.0 --trials 3 --count 256 --concurrency 32 --rate 1000
python scripts/reliability_benchmark.py --baseline-ref v0.2.0 --trials 3 --rounds 16
```

load_benchmark 连接专用 Cassandra，创建或覆盖 mooncql_loadbench.probe；热点分区和 32 个均匀分区分别运行固定并发及固定到达率。开环到达按预先确定的时间表进入有界隐式队列，工作线程不足时延迟调度，仍从计划时刻计算延迟，不静默丢弃迟到请求。每条逻辑样本保存 planned／enqueued／dispatched／completed 纳秒，全部成功、拒绝、超时与失败均计入分位数。RPC 另保留实际排队、首次写入尝试和完成的毫秒时间线；旧版没有绝对 RPC 时间戳，只保存原有 queue／execution 时长，不伪造发送时刻。

完整负载矩阵还交错关闭／启用观测；记录空载时钟与数组采样成本、客户端 CPU、进程生命周期峰值 RSS 和控制器自身 CPU。`--smoke` 仅选四组并保留其限定范围。基线与候选运行同一负载，稳定版仅适配等价 API 名称和当时可用的观测接口，原始 JSONL 与逐轮摘要保存在本地 `.artifacts/load-benchmark-*`。

reliability_benchmark 不依赖数据库，使用同一进程内的 TCP 模拟节点与 release 构建，三轮交错测量大请求等待、废弃 10 万行响应、blob／宽行／嵌套集合混合时的小查询尾延迟，以及一次 OVERLOADED 后的显式幂等重试。CPU 和峰值 RSS 包含服务端模拟与测试数据构造，不能当成驱动独占成本；取消排空不构造结果页，原始采样与候选的接收峰值同样归档。没有分配器采样时不把 RSS 当成对象分配量。只对可重复的热点采取性能改动，混合结果吞吐和小请求 P99 必须同时检查。
