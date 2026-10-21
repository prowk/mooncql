# 入门教程

[文档目录](README.md) · [连接配置](configuration.md)

本教程使用 0.2.0，在专用单节点 Cassandra 5.0.5 上创建表，写入三条事件并逐页读取。默认地址为 127.0.0.1:9042。

## 1. 准备数据库

安装 MoonBit native 工具链及平台 C 编译器。Windows 使用 MSVC，Linux 使用 GCC 或 Clang；启用 TLS 的 Linux 环境还需要 OpenSSL。

使用仓库的 Compose 启动演示数据库：

```sh
git clone https://github.com/prowk/mooncql.git
cd mooncql
docker compose up -d --wait --wait-timeout 360
```

默认环境无认证，仅用于本地演示。已有数据库时直接使用其地址与凭据，无需启动 Compose。请授予演示账户创建 mooncql_tutorial keyspace 和表的权限，或由管理员先创建。

## 2. 创建应用并安装驱动

在另一个目录运行：

```sh
moon new mooncql-demo
cd mooncql-demo
moon add prowk/mooncql@0.2.0
moon add moonbitlang/async@0.22.3
```

应用直接导入异步运行时，因此需要显式添加 async 依赖；驱动的间接依赖不能替代应用的直接声明。将 `cmd/main/moon.pkg` 替换为：

```moonbit
import {
  "moonbitlang/async",
  "moonbitlang/core/env",
  "moonbitlang/core/string",
  "prowk/mooncql/client",
  "prowk/mooncql/protocol",
}

pkgtype(kind: "executable")
```

## 3. 编写完整程序

将 `cmd/main/main.mbt` 替换为以下代码。仓库中的同一程序位于 [cmd/tutorial](../cmd/tutorial/main.mbt)，可以直接运行 `moon run cmd/tutorial`。

```moonbit
///|
async fn main {
  let config = @client.Config::new(
    host=@env.get_env_var("CQL_HOST").unwrap_or("127.0.0.1"),
    port=@string.parse_int(@env.get_env_var("CQL_PORT").unwrap_or("9042")),
    username?=@env.get_env_var("CQL_USERNAME"),
    password?=@env.get_env_var("CQL_PASSWORD"),
    compression=@env.get_env_var("CQL_COMPRESSION") == Some("lz4"),
  )
  @client.with_session(config=@client.SessionConfig::new(connection=config), session => {
    // 入门示例使用专用 keyspace；RF=1 仅适合单节点演示。
    ignore(
      session.query(
        "CREATE KEYSPACE IF NOT EXISTS mooncql_tutorial WITH replication = {'class':'SimpleStrategy','replication_factor':1}",
      ),
    )
    ignore(
      session.query(
        "CREATE TABLE IF NOT EXISTS mooncql_tutorial.events (device int, id int, message text, PRIMARY KEY (device,id))",
      ),
    )
    let insert = session.prepare(
      "INSERT INTO events (device,id,message) VALUES (?,?,?)",
      keyspace="mooncql_tutorial",
    )
    for id in 1..<4 {
      ignore(
        insert.execute([
          Integer(42),
          Integer(id),
          Text("来自 MoonBit 的事件"),
        ]),
      )
    }
    let select = session.prepare(
      "SELECT id,message FROM events WHERE device=?",
      keyspace="mooncql_tutorial",
    )
    let pages = select.pages(
      [Integer(42)],
      options=@protocol.QueryOptions::new(page_size=2),
    )
    let mut seen = 0
    while pages.next() is Some(page) {
      for index in 0..<page.rows.length() {
        let row = page.row(index)
        println(row.int("id"))
        println(row.text("message"))
        seen += 1
      }
    }
    assert_eq(seen, 3)
    println("Read 3 events")
  })
}
```

`with_session` 管理连接和后台任务；退出作用域时会关闭并等待它们结束。Session 应随应用复用，不必为每次查询新建。`prepare` 保留 CQL 和 keyspace，Session 更换物理连接后同一个业务语句仍能使用。

绑定参数使用 `Value` 的构造器，例如 Integer、Text 和 Null；驱动根据准备元数据校验参数。普通参数化查询也可使用 `session.query(cql, values=[...])`。显式 keyspace 可以避免并发 USE 或连接恢复引起的上下文差异。

Pager 每次 `next` 返回一页，直到 None。`Row.int` 和 `Row.text` 按列名读取；缺列、NULL 和类型不符是不同错误。可空列先用 `row.is_null(name)` 判断。分页不提供跨页快照一致性。

## 4. 运行与验证

```sh
moon run --target native cmd/main
```

程序输出 ID 1、2、3 及对应中文消息，最后输出 `Read 3 events`。同一示例可重复运行，会覆盖专用分区中的这三条记录，不会清空其他表。

需要密码认证、不同地址或 LZ4 时，以 PowerShell 为例：

```powershell
$env:CQL_HOST = '127.0.0.1'
$env:CQL_PORT = '9042'
$env:CQL_USERNAME = 'app_user'
$env:CQL_PASSWORD = 'your_password'
$env:CQL_COMPRESSION = 'lz4'
moon run --target native cmd/main
```

无认证环境不要设置用户名和密码。TLS 由 Config.tls 开启，详见 [TLS](tls.md)。库本身不自动读取以上环境变量，只有本教程程序显式读取它们。

## 5. 处理失败与继续学习

写入默认不重试。只有业务明确幂等时，才传入 `idempotent=true`；超时或取消不能证明服务端没有执行。一次业务流程可以共享 `Deadline::after(...)`，避免恢复或重试不断延长总时限。

先阅读[超时与取消](timeouts.md)、[重试](retries.md)和[连接健康](connection-health.md)；接入真实集群时再阅读[拓扑发现](topology.md)与[路由](routing.md)。需要检查协调节点、warnings 或 tracing 时使用 [with_info](execution-info.md)，应用运行指标见 [Metrics](metrics.md)。

停止本教程启动的 Compose 环境：

```sh
docker compose down
```

该命令需要在 mooncql 仓库目录运行。示例 keyspace 保留在数据库中，是否清理由应用自行决定。RF=1 只用于单节点入门，生产集群应按部署拓扑配置复制策略与一致性。
