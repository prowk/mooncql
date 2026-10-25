# 分页游标与恢复

[文档目录](README.md) · [入门教程](getting-started.md)

本文适用于 0.2.0。Connection、Prepared、Session 和 SessionPrepared 都提供 pages；next 返回一页，next_with_info 另外保留本页执行信息。Session 的 Pager 可以继续使用自动恢复后的连接。

```moonbit
let options = @protocol.QueryOptions::new(page_size=100)
let pages = session.pages(
  "SELECT id, message FROM app.events WHERE device=?",
  values=[Integer(42)], options~,
)
if pages.next() is Some(page) {
  // 先完成本页业务处理，再持久化下一页的游标。
  for index in 0..<page.rows.length() { println(page.row(index).text("message")) }
  let checkpoint = pages.cursor().to_bytes()
  // 将 checkpoint 保存到应用的持久存储。
  let restored = session.pages(
    "SELECT id, message FROM app.events WHERE device=?",
    values=[Integer(42)], options~,
    cursor=@client.PagingCursor::from_bytes(checkpoint),
  )
  while restored.next() is Some(next_page) { ignore(next_page.rows) }
}
```

游标冻结 CQL 原文、有效 keyspace、绑定值及次序、命名列表、一致性、page_size、serial_consistency、timestamp、now_in_seconds、skip_metadata、请求 tracing 和 custom payload。预处理分页还包含准备请求的上下文，但不绑定节点上的临时 statement ID。恢复必须重传相同上下文，不匹配时在发送请求之前抛出 Configuration；普通和预处理游标不能混用。custom payload 的 Map 插入次序不影响匹配。

普通 Connection 在创建 Pager 时冻结当前有效 keyspace，之后的 USE 不改变该 Pager。Session 使用显式 keyspace 或完整限定表名。相同的游标可用于同一集群的其他连接或重新创建的 SessionPrepared；跨集群、schema 或服务端版本变化后的有效性由服务端决定，不保证兼容。

cursor() 导出下一页的位置，初始游标表示尚未开始，完成游标的 is_done() 为 true，恢复后直接返回 None。仅成功收到可接受的 ROWS 页后推进；服务端错误、超时、取消、EOF、非 ROWS 结果和未变化的非空 paging state 都不会推进。重新调用 next 会提交相同续读位置；默认不隐式重放失败页。空页只要有新的 paging state 就继续。每个 Pager 只允许一个活动 next，活动期间 cursor() 也拒绝读取。

next 成功返回时驱动已经推进到下一页，不知道本页业务处理是否完成。调用方应在处理成功后保存游标；若业务处理失败，可用处理前的游标重新读取。本接口不提供业务层恰好一次处理。通过 options.paging_state 仍可传递原始状态，但原始字节没有上下文匹配保护；不能与 cursor 参数同时使用。

恢复后的普通查询重新请求完整元数据。普通 Session 每页可能更换协调节点，因此始终请求元数据；Prepared 使用所选连接自己的准备元数据。skip_metadata 仍参与上下文匹配，但会在需要完整元数据时由驱动关闭。分页各页可以观察到不同时间的数据，不保证跨页快照一致性；并发写入、删除、TTL 和 schema 变化可能影响结果，不能据此承诺无重复或无遗漏。

游标使用带版本的二进制容器，最大 32 MiB，其中上下文最多 16 MiB。未知版本、截断、非法长度、完成标志与续读状态冲突会被拒绝。Debug 隐藏查询和绑定值，但序列化字节可能包含这些数据，应用应按原始查询数据保护，避免写入公开日志。格式没有签名或加密，匹配检查用于防止意外误用；面对不可信客户端应由应用认证、签名或保存服务端游标标识。升级格式后可能需要重新开始查询。

测试包含更换 Connection、完成游标、空页、上下文变化、取消与迟到响应、并发限制，以及失败不推进。真实重启验收在专用 Cassandra 5.0.5 上保留普通和预处理 Pager，重启后继续各 84 行，并从持久化游标重新创建两个 Pager；独立 Python 驱动再使用两个原始续读状态核对同样结果。

开发分支额外运行固定种子的 1536 次字节变异、每个截断位置、Int 极端声明长度、尾部多余字节及完成标志冲突。接受的合法变异必须逐字节往返；修改查询绑定的合法容器仍可能通过格式解析，后续恢复时必须匹配实际查询上下文。解析长度超限在复制正文前失败，序列化也在构造大缓冲前检查总长度。这些格式检查不进行网络 I/O。

复现实际重启测试：先启动本仓库专用 Compose 服务，按认证设置 CQL_USERNAME / CQL_PASSWORD 和 CQL_COMPRESSION，再安装 scripts/requirements-reference.txt，运行 `python scripts/session_recovery.py --docker-compose`。该脚本会停止并重启这个 Compose 服务，创建或清空 mooncql_recovery_a / mooncql_recovery_b 下的测试表。普通及预处理查询的入口均在 cmd/recovery/main.mbt。
