///|
pub(all) enum SchemaAgreementState {
  Unknown
  Disagreed
  Agreed
} derive(Eq, @debug.Debug)

///|
pub extend SchemaAgreementState with Eq::{equal, not_equal}

///|
pub extend SchemaAgreementState with @debug.Debug::{to_repr}

///|
pub(all) struct SchemaVersionObservation {
  endpoint : Endpoint
  generation : Int32
  version : Bytes?
  error : Error?
}

///|
pub(all) struct SchemaAgreement {
  state : SchemaAgreementState
  observations : Array[SchemaVersionObservation]
  excluded : Array[Endpoint]
  membership_changed : Bool
  timed_out : Bool
  checked_at : Int64
  error : Error?
}

///|
fn SchemaAgreement::snapshot(self : SchemaAgreement) -> SchemaAgreement {
  {
    ..self,
    observations: self.observations.copy(),
    excluded: self.excluded.copy(),
  }
}

///|
pub(all) struct SchemaAgreementConfig {
  wait_after_ddl : Bool
  timeout_ms : Int32
  poll_interval_ms : Int32
  max_nodes : Int32
}

///|
pub fn SchemaAgreementConfig::new(
  wait_after_ddl~ : Bool = false,
  timeout_ms~ : Int32 = 10000,
  poll_interval_ms~ : Int32 = 100,
  max_nodes~ : Int32 = 1024,
) -> SchemaAgreementConfig {
  { wait_after_ddl, timeout_ms, poll_interval_ms, max_nodes, }
}

///|
fn SchemaAgreementConfig::validate(
  self : SchemaAgreementConfig,
) -> Unit raise DriverError {
  validate_range("schema_agreement.timeout_ms", self.timeout_ms, 1, 2147483647)
  validate_range(
    "schema_agreement.poll_interval_ms",
    self.poll_interval_ms,
    1,
    60000,
  )
  validate_range("schema_agreement.max_nodes", self.max_nodes, 1, 65536)
}

///|
fn unknown_schema() -> SchemaAgreement {
  {
    state: Unknown,
    observations: [],
    excluded: [],
    membership_changed: false,
    timed_out: false,
    checked_at: @async.now(),
    error: None,
  }
}

///|
async fn Session::inspect_schema(
  self : Session,
  deadline : Deadline,
) -> SchemaAgreement {
  let participants : Array[(SessionNode, Connection)] = []
  let excluded = []
  for node in self.nodes {
    if node.representative() is Some(connection) {
      participants.push((node, connection))
    } else {
      excluded.push(node.endpoint)
    }
  }
  if participants.length() > self.config.schema_agreement.max_nodes {
    return {
      ..unknown_schema(),
      excluded,
      error: Some(Configuration("schema check exceeds max_nodes")),
    }
  }
  let reads : Array[async () -> SchemaVersionObservation] = participants.map(pair => {
    () => {
      let (node, connection) = pair
      let outcome = try {
        guard connection.query(
            "SELECT schema_version FROM system.local",
            deadline~,
          )
          is Rows(page) &&
          page.rows.length() == 1 else {
          raise Unexpected("missing local schema version")
        }
        guard page.get(0, "schema_version") is Uuid(version) &&
          version.length() == 16 else {
          raise Unexpected("invalid local schema version")
        }
        if connection.closed || !node.owns(connection) {
          raise Unexpected("schema observer connection was replaced")
        }
        Ok(version)
      } catch {
        error => Err(error)
      }
      match outcome {
        Ok(version) =>
          {
            endpoint: node.endpoint,
            generation: connection.generation,
            version: Some(version),
            error: None,
          }
        Err(error) =>
          {
            endpoint: node.endpoint,
            generation: connection.generation,
            version: None,
            error: Some(error),
          }
      }
    }
  })
  let observations = @async.all(reads, max_concurrent=8)
  let current = []
  for node in self.nodes {
    if node.representative() is Some(_) {
      current.push(node)
    }
  }
  let membership_changed = current.length() != participants.length() ||
    !participants.all(pair => {
      current.any(node => physical_equal(node, pair.0)) &&
      pair.0.owns(pair.1) &&
      !pair.1.closed
    })
  let state : SchemaAgreementState = if membership_changed ||
    observations.is_empty() ||
    observations.any(observation => observation.version is None) {
    Unknown
  } else if observations.all(observation => {
      observation.version == observations[0].version
    }) {
    Agreed
  } else {
    Disagreed
  }
  {
    state,
    observations,
    excluded,
    membership_changed,
    timed_out: deadline.remaining_ms() == 0,
    checked_at: @async.now(),
    error: None,
  }
}

///|
/// 读取本 Session 当前存活节点的本地 schema_version；未查询或失败的节点不能伪装为同意。
pub async fn Session::check_schema_agreement(
  self : Session,
  deadline? : Deadline,
) -> SchemaAgreement {
  let deadline = self.operation_deadline(deadline)
  self.with_operation(SchemaCheckOperation, () => self.inspect_schema(deadline))
}

///|
async fn Session::wait_schema_internal(
  self : Session,
  deadline : Deadline,
) -> SchemaAgreement {
  let cap = @async.now() + self.config.schema_agreement.timeout_ms.to_int64()
  let deadline = Deadline::{
    at: if deadline.at < cap {
      deadline.at
    } else {
      cap
    },
  }
  let mut report = unknown_schema()
  while !self.closed && deadline.remaining_ms() > 0 {
    report = self.inspect_schema(deadline)
    if report.state == Agreed || report.error is Some(_) {
      return report
    }
    // 权限拒绝不会通过重复轮询修复；完整保留未知状态与服务端原因。
    if report.observations.any(observation => {
        observation.error is Some(Server(error)) && error.code == 0x2100
      }) {
      return report
    }
    let remaining = deadline.remaining_ms()
    if remaining > 0 {
      @async.sleep(
        if remaining < self.config.schema_agreement.poll_interval_ms {
          remaining
        } else {
          self.config.schema_agreement.poll_interval_ms
        },
      )
    }
  }
  {
    ..report,
    timed_out: deadline.remaining_ms() == 0,
    error: if self.closed {
      Some(Closed)
    } else {
      report.error
    },
  }
}

///|
/// 有界等待收敛，超时返回最后一次报告而不是重放任何 DDL。
pub async fn Session::wait_schema_agreement(
  self : Session,
  deadline? : Deadline,
) -> SchemaAgreement {
  let deadline = self.operation_deadline(deadline)
  self.with_operation(SchemaWaitOperation, () => {
    self.wait_schema_internal(deadline)
  })
}

///|
async fn Session::finish_schema(
  self : Session,
  execution : Execution[@protocol.ResultSet],
  deadline : Deadline,
) -> SchemaExecution[@protocol.ResultSet] {
  if execution.value is SchemaChanged(_) &&
    self.config.schema_agreement.wait_after_ddl {
    let agreement = self.wait_schema_internal(deadline) catch {
      error => { ..unknown_schema(), error: Some(error), }
    }
    // DDL 响应已经成功，等待失败仅写入独立报告，不修改执行结果、不进入重试。
    {
      value: execution.value,
      info: execution.info,
      schema_agreement: Some(agreement.snapshot()),
    }
  } else {
    { value: execution.value, info: execution.info, schema_agreement: None, }
  }
}
