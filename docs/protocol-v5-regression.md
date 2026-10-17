# Cassandra 5.0.5 协议回归清单

参考版本为 Apache Cassandra `cassandra-5.0.5`，标签解析后的提交为
[`c8abc9f3e1bb46bc4d699c3a167e43df62b9bec8`](https://github.com/apache/cassandra/tree/c8abc9f3e1bb46bc4d699c3a167e43df62b9bec8)。
参考文件及原始字节 SHA-256 保存在 [源码清单](../fixtures/cassandra-5.0.5-reference.json)，不跟随可变分支更新。

| 检查项 | 固定行为 | 回归证据 |
| --- | --- | --- |
| 握手切帧 | OPTIONS／STARTUP 与对应 SUPPORTED、READY／AUTHENTICATE 不套外层帧；READY／AUTHENTICATE 后包括 AUTH_RESPONSE 在内均套帧 | `client/negotiation_test.mbt`、`client/v5_test.mbt`，无认证／密码与普通帧／LZ4 四种组合 |
| 握手后 OPTIONS | 与其他请求一样使用已协商的外层帧，SUPPORTED 也使用该帧格式 | `client/negotiation_test.mbt` |
| CRC24 | 初值 `0x875060`、多项式 `0x1974f0b`，校验普通帧头前三字节或 LZ4 帧头前五字节 | `framing/frame_test.mbt` 固定字节和逐字节破坏测试 |
| CRC32 | 标准 CRC32 先输入 `fa 2d 55 ca`，再输入线上载荷；尾部四字节为小端 | `scripts/protocol_reference.py` 使用独立 Python zlib 复现 |
| 协商 LZ4 后的原始载荷 | 仍为八字节帧头，`uncompressedLength == 0` 表示直接使用载荷；不是按 compressedLength 是否为零判断 | `lz4_raw_abc` 固定字节、`framing/frame_test.mbt`、实库四组合 |
| 分片边界 | 单帧最多 131071 字节；更大 envelope 独占连续非 self-contained 帧；一个 self-contained 帧可容纳多个完整 envelope | `protocol/reference_test.mbt` 覆盖 131070／131071／131072／262142／262143；`protocol/decoder_test.mbt` 覆盖消息头各切分位置 |
| 扩展字段 | 忽略 envelope 未识别标志与已解码消息的未来尾部字段；不把尾部字节误作下一 envelope | `protocol/reference_test.mbt`、`protocol/frame_test.mbt` |
| 附加字段顺序 | tracing id、warnings、custom payload、消息正文 | `protocol/frame_test.mbt` |
| 非法输入 | 帧头先校验再按长度读取；载荷校验后才解压；重组受消息上限约束；截断、损坏和跨消息分片失败 | `framing/frame_test.mbt`、`protocol/decoder_test.mbt`、`client/failures_test.mbt` |

字节样例保存在 [v5-wire.json](../fixtures/v5-wire.json)，包含普通帧、LZ4 原始载荷、握手前后 OPTIONS、READY 和 envelope 扩展。复现命令：

```sh
python scripts/protocol_reference.py
moon test --target native --deny-warn
```

可将源码清单中的 URL 固定到上述提交下载到本地目录，再校验原始文件：

```sh
python scripts/protocol_reference.py --sources .tools/cassandra-5.0.5-reference
```

`FrameDecoderLZ4.java` 的 `unpackFrame` 以解压长度零识别原始载荷。
`ExecuteMessage.java` 对 LWT 总是返回本次结果元数据，不设置 METADATA_CHANGED；普通预处理结果才按结果元数据 ID 判断变化与省略。
这些语义以清单中的固定源码及真实 Cassandra 5.0.5 测试为准。
