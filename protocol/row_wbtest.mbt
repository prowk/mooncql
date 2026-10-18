///|
test "all rows in a page share one lazily built column index" {
  let page = Page::new(
    [{ keyspace: "ks", table: "t", name: "id", typ: Int, }],
    [[Integer(1)], [Integer(2)]],
  )
  assert_true(page.schema.lookup is None)
  let first = page.row(0)
  let second = page.row(1)
  assert_eq(first.int("id"), 1)
  guard page.schema.lookup is Some(lookup) else {
    fail("missing cached lookup")
  }
  assert_eq(lookup.length(), 1)
  // 修改私有索引来验证后续读取复用同一个 Map，而不是重新扫描列数组。
  lookup["alias"] = 0
  assert_eq(second.int("alias"), 2)
  assert_eq(page.get(0, "alias"), @types.Value::Integer(1))
  assert_eq(first.value("alias"), @types.Value::Integer(1))
}
