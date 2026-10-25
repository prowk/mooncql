# 版本与发布包验收

[文档目录](README.md) · [迁移说明](migration.md) · [申报验收](acceptance.md)

## 安装与文档对应

| 版本 | 安装 | API 和文档 |
| --- | --- | --- |
| 申报版 0.1.0 | `moon add prowk/mooncql@0.1.0` | [固定标签中的 README](https://github.com/prowk/mooncql/blob/v0.1.0/README.md)、[历史 Release](https://github.com/prowk/mooncql/releases/tag/v0.1.0) |
| 历史版 0.2.0 | `moon add prowk/mooncql@0.2.0` | [稳定版入门](https://github.com/prowk/mooncql/blob/v0.2.0/docs/getting-started.md)、[稳定 Release](https://github.com/prowk/mooncql/releases/tag/v0.2.0) |
| 当前稳定版 0.2.1 | `moon add prowk/mooncql@0.2.1` | [入门教程](getting-started.md)、[Release](https://github.com/prowk/mooncql/releases/tag/v0.2.1) |

直接使用异步应用入口的独立项目还须执行 `moon add moonbitlang/async@0.22.3`，在 `moon.pkg` 导入自身直接使用的包。历史 README 未单独列出直接依赖的安装命令；不能依靠驱动的传递依赖代替声明应用依赖。

历史版只使用 Connection／Prepared／Pager、`Page.get` 和基础 Value；不使用后续新增的 Session、Row、TLS 或心跳参数。[三个场景](examples.md)刻意保持这组共同 API，历史及当前发布包都单独编译和运行。0.1.0 取消与超时关闭整条连接，0.2.0 的迟到响应排空与 Session 恢复应查阅对应新版文档。

## 可重复的消费验收

完整发布包验收在发布前、修改独立消费示例或依赖配置时执行。普通功能修改主要检查本地源码；CI 依据提交差异决定是否安装已发布包。手动触发 `checks` 或推送标签会强制执行，无法确定变更范围时也执行。

```sh
python scripts/package_acceptance.py
```

脚本为 合同内每个固定版本各创建全新 MoonBit 模块，声明注册表版本与 async 直接依赖，通过 Mooncakes 下载依赖并构建 native 程序。不会链接仓库里的 client、protocol 等源码；复制的仅是场景应用代码。版本合同固定在 [releases.json](../fixtures/releases.json)，不是浮动依赖。

检查内容包括 GitHub Release 已公开且非预发布、当前 stable 与 GitHub latest 一致、源码标签指向固定提交、模块名称和版本、Apache-2.0 许可证、公开 `.mbti`、全部已安装 `.mbt`／C 运行时源码与标签逐字节一致（仅统一 CRLF/LF）。CI 在 Windows 和 Linux 分别完成这些检查。

稳定版消费项目还编译 README 原始 Session 片段，报告 `readme_compiled=true`；0.1.0 不复制这段新接口。它的默认无认证运行由源码实库 CI 单独检查，三个可配置场景仍在历史及当前发布包中分别实际运行。

连接专用 Cassandra 后执行完整运行验收：

```sh
python scripts/package_acceptance.py --run
```

这会让每个版本都执行三个场景、预期错误分支及已有数据只读模式。输入通过与[场景示例](examples.md)相同的 `CQL_*` 环境变量传递。结果、工具链、OS、标签、许可和公开 API／源码指纹位于 `.artifacts/package-acceptance-*`，CI 自动归档；任一步失败不会报告整个版本通过。

新增稳定版本时必须显式更新版本合同，并保留 0.1.0 的历史验收；不得移动已发布标签、用当前源码覆盖历史包，或用新版 API 片段冒充旧版教程。
