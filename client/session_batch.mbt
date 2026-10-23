///|
enum SessionBatchBinding {
  Query(String, Array[@types.Value])
  Prepared(SessionPrepared, Array[@types.Value])
}

///|
/// Session 批处理项；构造时深拷贝绑定值，不保存物理连接或预处理 ID。
pub struct SessionBatchStatement {
  binding : SessionBatchBinding
}

///|
/// 构造普通批处理语句；未限定的表名使用整批 options.keyspace。
pub fn SessionBatchStatement::query(
  cql : String,
  values? : Array[@types.Value] = [],
) -> SessionBatchStatement raise {
  { binding: Query(cql, @types.snapshot(values)), }
}

///|
/// 冻结参数并绑定逻辑预处理语句，发送时才取得所选连接上的实际 ID。
pub fn SessionPrepared::bind_batch(
  self : SessionPrepared,
  values : Array[@types.Value],
) -> SessionBatchStatement raise {
  let values = @types.snapshot(values)
  if values.length() != self.parameters.length() {
    raise Configuration("incorrect prepared parameter count")
  }
  for i, value in values {
    @types.validate(self.parameters[i].typ, value)
  }
  { binding: Prepared(self, values), }
}

///|
/// 在同一协调连接上准备、编码并发送一次整批操作，所有阶段共用总 Deadline。
pub async fn Session::batch_with_info(
  self : Session,
  statements : Array[SessionBatchStatement],
  kind? : @protocol.BatchType = Logged,
  options? : @protocol.QueryOptions = @protocol.QueryOptions::new(),
  deadline? : Deadline,
  routing? : RoutingHint,
) -> Execution[Unit] {
  let deadline = self.operation_deadline(deadline)
  let statements = statements.copy()
  let options = options.snapshot()
  let provisional = statements.map(statement => {
    match statement.binding {
      Query(cql, values) => @protocol.BatchStatement::Query(cql, values)
      Prepared(statement, values) => {
        if !physical_equal(statement.session, self) {
          raise Configuration("batch statement belongs to another session")
        }
        @protocol.BatchStatement::Prepared(b"", values)
      }
    }
  })
  // 在选节点前检查空批次、查询专用选项、递归和帧大小，避免无效请求触发准备。
  let request = @protocol.batch(provisional, kind~, options~)
  if request.body.length() > self.config.connection.max_frame_bytes {
    raise Configuration("request exceeds frame limit")
  }
  let charge = request.body.length().to_int64() + 9L
  self.with_operation(BatchOperation, () => {
    let connection = self.select(deadline, charge, hint?=routing)
    let encoded = []
    let history = []
    for statement in statements {
      match statement.binding {
        Query(cql, values) =>
          encoded.push(@protocol.BatchStatement::Query(cql, values))
        Prepared(statement, values) => {
          let preparation = statement.statement_for(
            connection, deadline, charge,
          ) catch {
            error => raise error_with_history(error, history)
          }
          if !preparation.info.cached {
            history.push(preparation.info)
          }
          encoded.push(preparation.value.bind_batch(values)) catch {
            error => raise error_with_history(error, history)
          }
        }
      }
    }
    // 发送失败、结果未知和 UNPREPARED 均由调用方处理，绝不重选节点重放 BATCH。
    let execution = connection.batch_with_info(
      encoded,
      kind~,
      options~,
      deadline~,
    ) catch {
      error => raise error_with_history(error, history)
    }
    let previous = history.copy()
    for prior in execution.info.previous {
      previous.push(prior)
    }
    { ..execution, info: { ..execution.info, previous, }, }
  })
}

///|
/// 发送一次 Session 批处理；失败保留原始错误类型，完整执行信息见 batch_with_info。
pub async fn Session::batch(
  self : Session,
  statements : Array[SessionBatchStatement],
  kind? : @protocol.BatchType = Logged,
  options? : @protocol.QueryOptions = @protocol.QueryOptions::new(),
  deadline? : Deadline,
  routing? : RoutingHint,
) -> Unit {
  ignore(self.batch_with_info(statements, kind~, options~, deadline?, routing?)) catch {
    ExecutionError(error, _) => raise error
    error => raise error
  }
}
