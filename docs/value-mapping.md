# 应用类型映射

[文档目录](README.md) · [Row 与值](rows.md) · [批处理与生命周期](development-api.md)

本页适用于**0.2.1 和 0.2.2**，新接口位于 `prowk/mooncql/mapping`。映射器由应用显式声明 CQL 类型和转换函数；不推断表结构、不生成查询，也不自动保存应用对象。

## Value 与 Row

`ValueCodec::new(cql_type, encode, decode)` 将应用类型与 `Value` 对应。编码回调接收应用值与 `EncodeContext`，通过 `context.field(name, child_codec, value)` 或 `item(index, child_codec, value)` 组合子字段。解码回调接收 `ValueReader`，通过 `field(name)`／`item(index)` 和 `read(child_codec)` 读取嵌套 UDT／tuple。其他标量和集合可用 `reader.value()` 取得独立 Value 后显式转换。

`int_codec()`、`text_codec()`、`bool_codec()` 分别精确对应 CQL int、varchar／text、boolean。类型不隐式收窄或互换；例如 bigint 不会自动成为 Int，ascii 也不会假装成 varchar。其他类型使用 `ValueCodec::new` 声明实际 CQL 类型。

`RowCodec::new(reader => ...)` 将查询行组合成应用对象，`reader.column(name).read(codec)` 使用行的真实列类型核对映射器。重复列名沿用 Row 的第一列规则，建议查询显式指定别名。

| 情况 | 默认行为 | 显式选择 |
| --- | --- | --- |
| 缺列／缺 UDT 字段／越界 tuple 下标 | `MissingField` | 仅行缺列可通过 `decode(row, missing=MissingAsNull)` 视为 NULL |
| NULL | `NullValue` | `codec.optional()` 将 NULL 与 `None` 对应 |
| Empty、空文本、空 blob | 保留 Value 区别；标量编解码器检查实际类型 | 自定义解码函数明确处理 |
| 类型／范围不匹配 | `TypeMismatch` 或 `InvalidValue` | 修正映射器与 schema，不进行隐式转换 |

`MissingAsNull` 与 `optional()` 必须分别选择：前者不会让必填字段自动获得默认值；后者不会静默吞掉默认策略下的缺列。应用可以在得到 None 后自行使用默认值。

## 嵌套结构示例

以下片段来自可运行的 [cmd/value-mapping](../cmd/value-mapping/main.mbt)，定义结构、UDT 与嵌套 tuple 的显式映射：

<!-- mapping-example:start -->

```moonbit
///|
struct Place {
  street : String
  coordinate : (Int32, String?)
} derive(Eq, @debug.Debug)

///|
fn place_codec() -> @mapping.ValueCodec[Place] raise {
  let number = @mapping.int_codec()
  let text = @mapping.text_codec()
  let optional_text = text.optional()
  let pair = @mapping.ValueCodec::new(
    Tuple([Int, Varchar]),
    (coordinate : (Int32, String?), context) => {
      TupleValue([
        context.item(0, number, coordinate.0),
        context.item(1, optional_text, coordinate.1),
      ])
    },
    reader => (reader.item(0).read(number), reader.item(1).read(optional_text)),
  )
  @mapping.ValueCodec::new(
    Udt("mooncql_mapping", "place", [
      ("street", Varchar),
      ("coordinate", pair.cql_type()),
    ]),
    (place : Place, context) => {
      UdtValue([
        ("street", context.field("street", text, place.street)),
        ("coordinate", context.field("coordinate", pair, place.coordinate)),
      ])
    },
    reader => {
      street: reader.field("street").read(text),
      coordinate: reader.field("coordinate").read(pair),
    },
  )
}
```

<!-- mapping-example:end -->

完整入口还演示 `RowCodec`，逐字节比较直接 Value 与映射编码，并检查还原后的对象相等。无需数据库即可运行：

```sh
moon run cmd/value-mapping
```

设置 `CQL_MAPPING_INTEGRATION=1` 后连接专用测试 Cassandra。沿用 `CQL_HOST`、`CQL_PORT`、`CQL_USERNAME`、`CQL_PASSWORD`、`CQL_COMPRESSION`，入口创建 `mooncql_mapping.place` UDT 与专用表，实际准备／绑定写入，再把原生 UDT／tuple 结果映射回来，并排空 Session。该模式需要 DDL 和读写权限，不应指向生产库。

## 错误与边界

错误为 `MappingError(path, reason)`，如 `$["home"]["coordinate"][0]`。字段名按 JSON 字符串转义，带点号或引号的列名不会与嵌套层级混淆。通过 EncodeContext 调用子编码器时，应用回调错误也保留完整路径。未知回调异常转换为 `CallbackFailed`，错误不附带对象或绑定值；自定义 MappingError 的路径和信息由应用负责。

编码器类型、输出 Value、解码输入和行元数据均使用独立快照。映射校验限制深度小于 32、每个 Value／整行最多 1000000 个值节点，并继续调用原有类型、范围、集合长度、NULL／UNSET 和二进制编码校验。UNSET 不作为应用对象映射值；需要 UNSET 时使用底层显式绑定接口。已有 Prepared 的参数类型校验、帧大小和连接额度限制继续生效。

映射有额外的校验和复制成本，适合需要明确应用模型的路径；直接 Value 和 Row getter 接口继续可用。CI 编译并运行示例，四种认证／压缩组合另运行真实绑定与读取；回归检查嵌套错误、缺列／NULL 策略、快照隔离和相同字节。
