# mooncql

用 MoonBit 实现的 Cassandra CQL 原生协议 v4 异步驱动。项目处于初步开发阶段，支持范围和验证结果随实现更新。

协议编解码使用 MoonBit，网络复用官方 `moonbitlang/async`。目标是让 MoonBit 原生后端直接访问 Cassandra；首版围绕一个显式配置的协调节点建立完整查询流程。

## 开发

需要 MoonBit 工具链。默认构建目标为 native。

```sh
moon check
moon test
moon info
moon fmt
```

## 实施里程碑

1. 工程结构、许可证和验证命令。
2. 有边界检查的二进制游标与写入器。
3. v4 帧头及消息前缀。
4. CQL 标量类型与无损值表示。
5. 握手和普通查询请求。
6. 结果元数据、行与结构化服务端错误。
7. 预处理与分页协议。
8. 原生 TCP 连接、认证及真实查询。
9. 同连接多路复用与生命周期。
10. 高层预处理及逐页消费接口。
11. 集合类型、参数校验与异常输入覆盖。
12. 故障模拟、真实数据库交叉验证、示例与文档。

每个里程碑以实际行为及相关测试为完成依据。集群发现、智能路由、压缩与协议 v5 后续考虑。

## 依据

- [Apache CQL binary protocol v4](https://github.com/apache/cassandra/blob/cassandra-4.1/doc/native_protocol_v4.spec)
- [Apache GoCQL](https://github.com/apache/cassandra-gocql-driver)
- [MoonBit async](https://github.com/moonbitlang/async)

Apache-2.0，见 LICENSE。
