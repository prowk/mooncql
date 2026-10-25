# 连续事件写入、分页与节点故障示例

[文档目录](README.md) · [入门教程](getting-started.md)

本文适用于 0.2.1。入口为 cmd/soak/main.mbt，控制器为 scripts/long_run.py。可以先执行短时混合负载和周期故障验证。连续六小时及长期内存趋势验证作为按需安排的后续验证，尚未执行。

示例使用独立三节点 Cassandra 5.0.5 集群，在 dc1 配置 RF=3，以 QUORUM 读写。同时演示持续事件写入、类型化读取、精确 bigint、分页游标、Session 自动恢复、显式幂等读取、LWT、同分区 unlogged BATCH、缓存淘汰、schema 事件及控制连接。写入覆盖固定分区和 ID，测试数据规模保持有界。

CQL_HOST 指定客户端连接地址，默认为 127.0.0.1；它同时用于种子和发现后的地址映射。CQL_CLUSTER_PORTS 指定三个对外端口，默认 19052 / 19053 / 19054。Docker 控制器读取各容器的广播地址并映射到这些客户端端点。使用专用 WSL 实例时，也可连接同机 WSL NAT 地址，避开本地实测中 localhost 转发路径在服务重启后超时的情况；无需修改驱动的拓扑地址或共享防火墙设置。

在 PowerShell 中启动专用环境：

```powershell
$env:CQL_AUTHENTICATOR = 'PasswordAuthenticator'
$env:CQL_USERNAME = 'cassandra'
$env:CQL_PASSWORD = 'cassandra'
$env:CQL_COMPRESSION = 'lz4'
docker compose -f compose.cluster.yaml up -d --wait --wait-timeout 360
```

先运行六分钟的故障演示：

```powershell
python scripts/long_run.py --docker-compose --smoke --seconds 360 --fault-interval 60 --down-seconds 5
```

控制器依次停止一个节点，确认 DOWN，等待指定时间后重新启动，确认三节点恢复 UP。初始数据准备后会修复专用集群 system_auth 的 RF=3 副本。运行中保留同一个 Session 和预处理对象；统计明确的传输失败、读写超时、暂时不可用，以及废弃请求达到数量或存活上限所触发的连接回收。连接回收仍作为失败计数，不被当成请求成功，也不自动重放写入。数据或协议校验失败会终止测试。脚本恢复自己停止的节点。

以下为按需执行的长期验证入口，不属于默认验收。不带 --smoke 的默认运行请求实际连续六小时：

```powershell
python scripts/long_run.py --docker-compose
```

正式运行要求至少 21600 秒，默认每 300 秒执行一次故障，节点保持 DOWN 至少 15 秒。短运行标记为 smoke，不计作六小时通过。控制器检查运行源文件与控制脚本摘要，运行中变更会使验收失败；长时间无进度、明显心跳间隔或系统休眠也不能作为连续负载通过。

Windows 控制器在运行作用域内通过 [SetThreadExecutionState](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setthreadexecutionstate) 请求防止空闲睡眠，结束或异常退出时恢复该线程的原状态。它不要求显示器常亮，不修改电源计划，也不能阻止用户主动睡眠；主动睡眠导致的心跳中断仍会使验收失败。

结果目录为 .artifacts/long-run-*，latest-long-run-dir.txt 指向最近一次运行：

| 文件 | 内容 |
| --- | --- |
| manifest.json | 源码与二进制摘要、提交、工具链、请求时长、故障参数、进程及开始时间 |
| progress.json | 最近的计数、失败原因、延迟直方图、内存及资源快照 |
| samples.jsonl | 每约十秒的连续样本，不逐请求积累历史 |
| faults.jsonl | 节点停止与恢复时间、节点及负载位置 |
| result.json | 原生入口停止负载、关闭连接并等待任务组后的结果 |
| report.json | 控制器核对时长、资源、故障和内存趋势后的报告 |

操作计数以完成的逻辑操作为单位；一次分页操作读取 64 行，在第一页后序列化并恢复游标。Metrics 另统计实际 RPC。延迟使用毫秒直方图，保存分桶边界和最大值；纳秒分位数由[性能基准](performance.md)提供。失败原因只保存类别、服务端错误码、超时阶段及可能发送标志，不记录密码、CQL 或绑定值。

原始 JSON 中通过 ToJson 输出的 Int64 指标、操作计数和延迟桶使用十进制字符串，以保留精度；控制器验收时精确转换为 Python int，按数值比较进度与额度。`python -m unittest discover -s scripts/tests` 覆盖大于 2^53 的计数、字符串指标、进度回退和失败门槛，不能替代真实集群运行。

停止负载后核对 pending、废弃请求、等待数量和字节额度归零，再关闭 Session。最终报告要求后台任务句柄归零、建立的连接全部关闭；报告在外层 Session 任务组退出后才写出。缓存容量固定为每连接 16，运行快照逐次检查上限。

内存样本包含当前工作集 / RSS，以及 Windows PrivateUsage 或 Linux VmData，不能直接跨系统比较。正式分析跳过最多二十分钟预热，按五分钟分桶，以完成请求数拟合内存变化，保存斜率、近似置信下界、拟合优度和首尾值。超过 2 MiB 且有明显线性增长的结果不通过；原始样本仍需结合故障和负载审阅，统计门槛不是对全部泄漏的证明。

普通写入、LWT 和 BATCH 默认不自动重放；读取显式声明幂等并使用有界重试。结果未知的写入由应用按业务语义核对。BATCH 两条写入属于同一分区，展示合并发送，不将跨分区大批次当作吞吐优化。分页不保证跨页快照；示例使用固定 ID 对应固定值，以便在并发覆盖写入时验证结果。

结束后如需清理专用环境：

```powershell
docker compose -f compose.cluster.yaml down --volumes
```

兼容结论限于实际完成的 Cassandra 5.0.5 验收；其他 Cassandra 版本和 ScyllaDB 尚未实测。
