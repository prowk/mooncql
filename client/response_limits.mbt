///|
/// 不可变的接收限制，在启动作用域前构造并校验；不改变 Config 的公开记录字段。
pub struct ResponseLimits {
  body_bytes : Int
  rows : Int
  columns : Int
  value_nodes : Int
  depth : Int
}

///|
pub fn ResponseLimits::new(
  max_body_bytes? : Int = 16777216,
  max_rows? : Int = 1000000,
  max_columns? : Int = 65535,
  max_value_nodes? : Int = 1000000,
  max_depth? : Int = 32,
) -> ResponseLimits raise DriverError {
  if max_body_bytes < 1 {
    raise Configuration("max_body_bytes must be 1..2147483647")
  }
  if max_rows < 0 || max_rows > 1000000 {
    raise Configuration("max_rows must be 0..1000000")
  }
  if max_columns < 0 || max_columns > 65535 {
    raise Configuration("max_columns must be 0..65535")
  }
  if max_value_nodes < 1 || max_value_nodes > 1000000 {
    raise Configuration("max_value_nodes must be 1..1000000")
  }
  if max_depth < 1 || max_depth > 32 {
    raise Configuration("max_depth must be 1..32")
  }
  {
    body_bytes: max_body_bytes,
    rows: max_rows,
    columns: max_columns,
    value_nodes: max_value_nodes,
    depth: max_depth,
  }
}
