# 性能基准

[文档目录](README.md) · [开发指南](development.md)

`scripts/benchmark.py` 在隔离目录构建指定 Git 基线和当前工作区，以同一入口、工具链和专用数据库比较。数据校验失败立即停止，不将失败计作成功样本。

```sh
docker compose -f compose.benchmark.yaml up -d --wait --wait-timeout 360
python scripts/benchmark.py --baseline-ref 50fa621 --trials 3 --server-description "记录系统、JRE、堆大小和网络环境"
```

按 compose.benchmark.yaml 设置连接端口及认证环境变量。默认专用端口 19042；脚本创建或覆盖 mooncql_bench.probe 的测试分区。先使用 `--smoke` 检查环境，不能把它算作完整矩阵。

完整矩阵包含 132 个场景：64 和 400000 字节、重复和固定种子随机载荷、普通帧和 LZ4、并发 1、32、128，以及页大小 1、4、8。纯 codec 与纯 LZ4 场景独立于真实数据库读写和分页。

每场景默认三轮，记录吞吐、P50、P95、P99、进程 CPU 与峰值内存。分页同时记录完整查询和单页延迟。峰值内存覆盖整个进程生命周期；吞吐包含入口的正确性校验，不应解释为服务端极限或跨环境可比结果。

基线与当前的顺序由固定种子打乱。结果、工具链、源码及生成 C 摘要保存到本地 `.artifacts/performance-*`，不随源码或运行时包发布。评估优化时应保留全部样本、进行同代码校准并记录环境，不能仅选择有利场景。

0.2 包含按输入规模分配短块 LZ4 哈希表的优化。既有测量支持该局部优化，不据此宣称数据库整体提速。当前发布未重新运行完整性能矩阵，长期内存趋势也未验证。
