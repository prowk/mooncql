# 开发分支接口

[文档目录](README.md) · [稳定版教程](getting-started.md) · [版本说明](versions.md)

本页仅适用于当前源码分支，尚未包含在 Mooncakes 的 0.2.0 中。稳定版和历史版仍使用各自标签中的接口；不要将以下代码复制到只安装 0.2.0 的项目。

多节点 DDL 可配置 [schema agreement](schema-agreement.md) 等待；结果与等待状态分开保留，已成功的 DDL 不会因为等待超时而重放。

## Session 批处理

`SessionBatchStatement.query(cql, values?)` 构造普通项，`SessionPrepared.bind_batch(values)` 构造逻辑预处理项；两者在构造时深拷贝绑定值。`Session.batch` 和 `batch_with_info` 支持混合这两类项，默认 Logged，也支持 Unlogged 和 Counter。绑定结果属于创建它的 Session，不允许跨 Session 使用。

发送过程先选定一个协调连接，在该连接上准备所有预处理项，再编码并发送一次 BATCH。连接代次更换后会取得新连接自己的 ID。准备、锁等待、编码前校验和最终发送共用调用方的 Deadline；`options` 中的 keyspace、请求扩展和其他选项在第一次等待前取快照。使用显式 keyspace 或完整限定表名，不依赖跨连接的 USE 状态。

`batch_with_info` 返回 `Execution[Unit]`，其 `info` 属于 BATCH 响应，`previous` 保留实际进行的 PREPARE 响应；缓存命中不会伪造额外 RPC。失败的准备、BATCH 服务端错误、断线、超时与结果未知都不会自动重放整批操作，BATCH 中的 UNPREPARED 同样直接交给调用方处理。Connection 原有批处理和物理 Prepared 绑定语义保持不变，详见[批处理指南](batches.md)。

## 可插拔认证

`ConnectionBuilder.auth_provider` 接受 `AuthProvider`；省略时仍使用原有 username／password PasswordAuthenticator。两种配置不能同时提供。

`AuthProvider.password(credentials)` 在每次新连接建立时调用异步凭据工厂，工厂接收节点 Endpoint，返回 `(username,password)`。应用可在工厂中读取密钥管理系统的当前凭据；工厂返回的认证会话独立于其他连接，更新凭据不会终止已经认证的在途请求。

其他自定义交互使用 `AuthProvider.new((server_authenticator,endpoint) => Authenticator.new(initial_response, evaluate_challenge?, on_success?))`。三个回调均可异步：返回的 NULL、空 token 和非空 token 保持协议上的区别。没有实现 challenge 回调时，收到挑战会明确失败。

| 配置 | 默认值 | 上限与语义 |
| --- | --- | --- |
| `max_auth_rounds` | 16 | 1–128，包含初始 AUTH_RESPONSE；达到上限不再发送下一轮 |
| `max_auth_token_bytes` | 65536 | 0–16777216，同时限制输入挑战、成功 token 和输出响应 |
| `connect_timeout_ms` | 继承 timeout_ms | 工厂、回调、所有认证往返与 TCP／TLS 共享同一次连接预算 |

提供器异常与认证拒绝使用固定的 `Authentication` 错误说明，不传播可能带密码或 token 的服务端／回调原始消息。驱动不会记录 token；应用自己的回调也应避免记录凭据。多轮机制通过本地 TCP 模拟验证；真实服务端兼容声明目前仍限于 Cassandra PasswordAuthenticator，不额外声明 Kerberos 等机制已实测。

## 优雅排空

`Session.drain(deadline)` 立即进入排空状态，新 query、prepare、execute 和 batch 返回 `Draining`；已有逻辑操作可继续使用当前连接，包括一次合法的 UNPREPARED 恢复。排空停止发现刷新、新建连接、重连及新的心跳；不主动取消正在执行的业务请求。

`Connection.drain(deadline)` 的范围是该连接已接受的 RPC，包含额度队列中的等待者与尚待排空的迟到响应。它拒绝新的 RPC；不承诺让尚未开始的后续分页或新 PREPARE 作为旧请求继续执行。

| 返回值 | 含义 |
| --- | --- |
| `Drained` | 已接受操作已结束；业务操作本身仍可能返回服务端错误 |
| `DeadlineReached(n)` | 期限到达时尚有 n 个操作／RPC，已明确结束并回收剩余资源 |
| `Interrupted(n)` | 立即关闭、连接故障或排空调用被取消，打断了当时剩余的 n 个操作／RPC |

返回前会等待收发、回收与节点任务结束。并发和重复排空共享同一次关闭结果；取消排空调用也会关闭并等待清理，不能留下后台恢复。`close`／`shutdown` 仍保留立即取消方式，默认作用域退出行为不变。可用 `is_draining()` 查询状态；Session 关闭后 `resources()` 中 active、pending、waiting、stream 额度和后台任务句柄归零。

## 可运行示例

从源码根目录运行 `moon run cmd/features`。输入与[场景示例](examples.md)相同：`CQL_HOST`、`CQL_PORT`、`CQL_USERNAME`、`CQL_PASSWORD` 和 `CQL_COMPRESSION`。需在专用单节点 Cassandra 5.0.5 中拥有创建 **mooncql_examples** keyspace 和读写 features 表的权限；示例写入该表的 `device=42,id=1/2`，期望输出 `PASS development features rows=2 batch_attempts=1 resources=0`。

[完整源码](../cmd/features/main.mbt)在 Windows／Linux CI 编译，并在实库验收中运行。以下内容由文档检查器与源码逐字核对：

```moonbit
///|
async fn main {
  let provider = match
    (@env.get_env_var("CQL_USERNAME"), @env.get_env_var("CQL_PASSWORD")) {
    (Some(username), Some(password)) =>
      Some(@client.AuthProvider::password(_ => (username, password)))
    (None, None) => None
    _ => fail("set both CQL_USERNAME and CQL_PASSWORD")
  }
  let config = @client.ConnectionBuilder::new(
    host=@env.get_env_var("CQL_HOST").unwrap_or("127.0.0.1"),
    port=@string.parse_int(@env.get_env_var("CQL_PORT").unwrap_or("9042")),
    auth_provider?=provider,
    compression=@env.get_env_var("CQL_COMPRESSION") == Some("lz4"),
  )
  @client.with_session_builder(
    config=@client.SessionBuilder::new(
      connection=config,
      connections_per_node=@string.parse_int(
        @env.get_env_var("CQL_POOL_SIZE").unwrap_or("1"),
      ),
      schema_agreement=@client.SchemaAgreementConfig::new(wait_after_ddl=true),
    ),
    session => {
      ignore(
        session.query(
          "CREATE KEYSPACE IF NOT EXISTS mooncql_examples WITH replication={'class':'SimpleStrategy','replication_factor':1}",
        ),
      )
      ignore(
        session.query(
          "CREATE TABLE IF NOT EXISTS mooncql_examples.features(device int,id int,message text,PRIMARY KEY(device,id))",
        ),
      )
      let insert = session.prepare(
        "INSERT INTO features(device,id,message) VALUES(?,?,?)",
        keyspace="mooncql_examples",
      )
      let batch = [
        insert.bind_batch([Integer(42), Integer(1), Text("逻辑预处理")]),
        @client.SessionBatchStatement::query(
          "INSERT INTO features(device,id,message) VALUES(?,?,?)",
          values=[Integer(42), Integer(2), Text("普通语句")],
        ),
      ]
      let execution = session.batch_with_info(
        batch,
        kind=Unlogged,
        options=@protocol.QueryOptions::new(keyspace="mooncql_examples"),
      )
      let pages = session.pages(
        "SELECT id,message FROM mooncql_examples.features WHERE device=?",
        values=[Integer(42)],
        options=@protocol.QueryOptions::new(page_size=1),
      )
      let mut count = 0
      while pages.next() is Some(page) {
        for row in 0..<page.rows.length() {
          assert_eq(page.get(row, "id"), @types.Value::Integer(count + 1))
          count += 1
        }
      }
      assert_eq(count, 2)
      assert_eq(
        session.check_schema_agreement().state,
        @client.SchemaAgreementState::Agreed,
      )
      assert_eq(
        session.drain(@client.Deadline::after(2000)),
        @client.DrainOutcome::Drained,
      )
      assert_eq(session.resources().background_task_handles, 0)
      println(
        "PASS development features rows=\{count} batch_attempts=\{execution.info.attempt_count} resources=0",
      )
    },
  )
}
```

短时四组合入口 `cmd/integration` 额外断言 Session 混合 logged／unlogged／counter BATCH 的实际结果、动态 PasswordAuthenticator 和排空资源归零。确定性回归见 [Session 批处理](../client/session_batch_test.mbt)、[认证](../client/authentication_test.mbt)与[排空](../client/drain_test.mbt)。
