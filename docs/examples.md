# 三个独立场景

[文档目录](README.md) · [入门教程](getting-started.md) · [验收清单](acceptance.md)

三个目录各有自己的 `main.mbt` 和 `moon.pkg`，仅调用公开库接口，可从仓库根目录分别运行，也可由[消费验收脚本](../scripts/package_acceptance.py)复制到独立项目，通过 Mooncakes 安装的 0.1.0 和 0.2.0 分别构建运行。

## 环境和输入

使用专用 Cassandra 5.0.5，默认 `127.0.0.1:9042`。三个入口都读取 `CQL_HOST`、`CQL_PORT`、`CQL_USERNAME`、`CQL_PASSWORD`，`CQL_COMPRESSION=lz4` 启用压缩。可用 `docker compose up -d --wait` 启动专用单节点环境。

账号需要创建 **mooncql_examples** keyspace、建表、读写与 ALTER 权限，复制因子为 1。示例不适合作为生产表管理工具。`device-events` 删除指定设备的示例分区；`batch-audit` 删除指定批次分区；`data-inspector` 默认重建专用 inspection 表以得到确定的初始 schema。三个入口均使用 `with_connection` 回收连接与后台任务，异常也经过同一作用域退出；写入异常向调用方返回，不自动重放。

| 输入 | 默认值 | 作用 |
| --- | --- | --- |
| `CQL_EXAMPLE_ROWS` | `64` | 前两个场景的行数，范围 1–10000 |
| `CQL_DEVICE` | `42` | 设备或批次分区编号 |
| `CQL_MESSAGE` | `设备事件` | 设备场景的文本前缀 |
| `CQL_EXAMPLE_ERROR` | 未设置 | 设为 `1` 运行并断言预期服务端错误 |
| `CQL_INSPECT_EXISTING` | 未设置 | 设为 `1` 时，检查工具只读已初始化的示例表 |

## 设备事件服务

[源码](../examples/device-events/main.mbt)创建 `events(device,id,message,large_value,recorded_at,tags)`，主键为 `(device,id)`。最多 16 个并发预处理写入，Int64 保留大整数与毫秒时间戳；预处理 SELECT 以页大小 17 惰性读取，核对所有字段、行序与校验和。

输入按 `id=0..CQL_EXAMPLE_ROWS-1` 生成：文本为 `CQL_MESSAGE` 加 ID，大整数为 `9007199254740993 + id`，时间戳为 `1700000000000 + id` 毫秒，标签为 `['中文','moon']`；设备编号取 `CQL_DEVICE`。这组确定的数据便于发现字段损坏、乱序、重复和缺失。

```sh
moon run examples/device-events
```

默认输出 `PASS scenario=device-events rows=64 pages=4 checksum=2016`。页数为实际观察值，正确性不依赖固定页数。设置 `CQL_EXAMPLE_ERROR=1` 后，先得到 `PASS expected_error=invalid_column connection_usable=true`，证明无效列名被识别为 0x2200，业务错误后连接仍可用。

## 批量处理核对

[源码](../examples/batch-audit/main.mbt)创建 `batch_items(partition,id,message)`，按 `partition` 分区，每批最多 10 条，普通与预处理语句混合；分别运行 logged 和 unlogged，再以页大小 17 逐页核对。

```sh
moon run examples/batch-audit
```

默认输出两行，分别含 `kind=logged` 和 `kind=unlogged`，均为 `rows=64 pages=4 checksum=2016`。counter BATCH 的专用 counter 表和结果断言位于[实库 v5 验收](../cmd/integration/v5.mbt)。批处理用于同分区业务操作，不能把跨分区 BATCH 当作并发写入的性能优化。

`CQL_EXAMPLE_ERROR=1` 会发送已失效的预处理 ID，输出 `PASS expected_error=unprepared_batch replay=false`。该错误交给调用方处理，不重放整批操作。

## 已有数据检查

[源码](../examples/data-inspector/main.mbt)初始化 `inspection_address` UDT 和专用 `inspection` 表，检查 400000 字节 blob、负 duration、含中文的 tuple 和 UDT。对 `SELECT *` 预处理后增加 `note` 列，再执行省略元数据的读取，断言新列及后续缓存读取正确。

```sh
moon run examples/data-inspector
```

默认输出 `PASS scenario=data-inspector payload=400000 complex_types=true existing=false`。随后设置 `CQL_INSPECT_EXISTING=1` 重跑，输出 `existing=true`，该模式不执行 DDL 或写入；它要求默认模式已成功建立示例数据。

设置 `CQL_EXAMPLE_ERROR=1` 同样复现无效列错误并检查连接可用。畸形协议帧的错误分支不注入真实数据库，使用[故障回归](../client/v5_test.mbt)和[差分语料](../scripts/differential_boundaries.py)确定性复现。

PowerShell 设置环境变量的例子：

```powershell
$env:CQL_EXAMPLE_ERROR = '1'
$env:CQL_COMPRESSION = 'lz4'
moon run examples/device-events
moon run examples/batch-audit
moon run examples/data-inspector
$env:CQL_INSPECT_EXISTING = '1'
moon run examples/data-inspector
```
