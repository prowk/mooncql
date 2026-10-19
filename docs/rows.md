# Row 读取与精确转换

本文描述尚未发布的 main 分支。`page.row(index)` 返回共享本页列定义和列名索引的 Row；第一次按名称读取时构建索引，后续各行按名称查找不再扫描全部列。同名列返回第一列，建议在 CQL 中使用明确别名。

```moonbit
guard connection.query("SELECT id, message FROM app.events WHERE device=?", values=[Integer(42)]) is Rows(page) else { fail("expected rows") }
for index in 0..<page.rows.length() {
  let row = page.row(index)
  let id = row.int64("id")
  let message = if row.is_null("message") { "" } else { row.text("message") }
  println("\{id}: \{message}")
}
```

| 读取结果 | 错误或值 |
| --- | --- |
| 不存在的列 | `MissingColumn(column, expected)` |
| 类型化读取 NULL | `NullColumn(column, expected)` |
| 列类型不匹配 | `TypeMismatch(column, expected, actual)` |
| 越界行／列或被修改后宽度不匹配 | `InvalidRow(message)` |
| `row.value(name)`／`value_at(index)` | 原始 Value，NULL 保留为 `Null` |

text 接受 ascii／varchar；int 精确扩宽 tinyint／smallint／int，int64 另接受 bigint／counter。其他标量通过 boolean、double、float、bytes、inet、uuid、date、time、timestamp、decimal、varint、duration 读取。double／float 不隐式转换整数或 decimal。list／set／map／tuple／udt 返回底层 Value 数组，保留嵌套值与 NULL。

v5 的旧数据可能包含零长度的非字符串标量，底层表示为 `Value.Empty`，与 Null 不同。is_null 对 Empty 返回 false，类型化标量 getter 抛出 TypeMismatch，可通过 value 保留或显式处理。空 text 和 blob 仍分别是 Text("") 与 Bytes(b"")；省略尾部字段的 UDT／tuple 补为 Null。布尔解码接受任意非零字节为 true，编码统一使用 1。

解码一页 ROWS 最多生成 1000000 个 Value 节点：容器本身、元素、map 的键和值、显式 NULL，以及 UDT／tuple 补齐的尾部 NULL 都计入同一个预算。超限抛出 CodecError；查询大量嵌套值时应减小 page_size。该限制独立于帧字节数，避免很短的响应通过重复展开宽 UDT 占用大量内存。低层 `protocol.decode_result(..., max_value_nodes=...)` 可将上限调低到 1–1000000；单独调用 `types.decode_value` 默认也使用一百万节点预算，可传入同一个 `DecodeBudget::new(max_nodes=...)` 跨值累计。解码失败不会退还已消耗的预算；处理下一条独立消息时新建预算。

`Page::new(columns, rows, paging_state?, new_metadata_id?)` 创建独立元数据快照，检查行宽、类型深度和快照规模。公开 columns 用于展示；Row 和 Page.get 使用创建时的私有快照。修改公开 columns、嵌套类型数组或 columns_snapshot() 的结果不会污染 Row 和 Prepared 缓存。需要重命名时用 Page::new 创建新页。rows 及其 Value 数组仍可修改，读取时检查缺失位置和类型；修改不会重新验证所有值。已有 Page 结构字面量应迁移到构造函数。

精确值类型位于 types 包，均提供 to_value() 以用于绑定：

| 类型 | 创建与读取 | 精度及格式 |
| --- | --- | --- |
| CqlUuid | from_bytes／from_string、to_bytes／to_string | 原始 16 字节，小写连字符文本；不强制 UUID 版本 |
| CqlDate | from_days／from_string、days／to_string | 1970-01-01 起有符号 Int 天数，完整 CQL 范围 |
| CqlTime | from_nanos／from_string、nanos／to_string | 一天内 Int64 纳秒，HH:MM:SS 加可选九位小数 |
| CqlTimestamp | from_millis／from_string、millis／to_string | 完整 Int64 毫秒，UTC 输出；输入要求 T 和 Z 或 ±HH:MM 偏移 |
| CqlVarInt | from_bytes／from_decimal_string、to_bytes／to_decimal_string | 有符号大端二进制，任意精度整数文本 |
| CqlDecimal | from_parts(scale, bytes)／from_string、scale／unscaled | 保留 Int scale 和任意精度系数，不经过浮点 |

日期采用向前延伸的格里历，含公元 0 年。0–9999 年输出四位年，其他年份输出带符号且至少六位的扩展年份，例如 -5877641-06-23。扩展年份用于完整 CQL 范围，不宣称为 RFC 3339 四位年时间戳。拒绝非法日期和闰秒。timestamp 可输入最多九位小数，但毫秒以下非零时抛出 ConversionError，不进行舍入；time 保留纳秒。原始整数访问始终可用。

decimal.to_scientific_string() 输出精确系数及指数，保留正负 scale，包括 Int 边界；to_plain_string() 输出普通小数，负 scale 的独立标记不会保留在普通文本中。转换不删除小数尾随零。varint.to_bytes() 原样保留符号扩展，文本回转生成最短编码。

varint 和 decimal 文本转换默认限制 10000 位／字符，可通过 max_digits／max_chars 调整到 1–1000000。转换前检查输入和展开规模，避免极端 scale 生成超大字符串。超过限制抛出 ConversionError，可继续使用原始字节和 scale；限制不改变底层 Value 精度。

`python scripts/conversion_reference.py --check` 以固定种子 2026101817 使用 Python int、uuid 和 calendar 核对回归样例。日期参考按闰日计数及二分年份独立计算，普通年份另与 datetime 核对。修改生成器后运行 `python scripts/conversion_reference.py` 和 `moon fmt` 更新样例。真实 scripts/interop.py 双向核对日期与 timestamp 边界、纳秒时间、大整数和带尾随零的 decimal；timestamp 经服务端 cast 为 bigint 交给 Python，避开 datetime 的年份限制。可运行入口 cmd/interop 需要先由该 Python 脚本准备数据。
