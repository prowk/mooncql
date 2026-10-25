///|
priv struct OperationObservation {
  metrics : Metrics
  kind : OperationKind
  started : Int64
  mut outcome : RequestOutcome
  mut session_budget : Bool
}

///|
fn OperationObservation::new(
  metrics : Metrics,
  kind : OperationKind,
) -> OperationObservation {
  metrics.operations.logical_started += 1L
  metrics.emit_diagnostic(OperationStarted(kind))
  {
    metrics,
    kind,
    started: @async.now(),
    outcome: Cancelled,
    session_budget: false,
  }
}

///|
fn OperationObservation::finish(self : OperationObservation) -> Unit {
  let elapsed_ms = @async.now() - self.started
  let data = self.metrics.operations
  data.logical_ms += elapsed_ms
  match self.outcome {
    Succeeded => data.logical_succeeded += 1L
    Cancelled => data.logical_cancelled += 1L
    _ => data.logical_failed += 1L
  }
  self.metrics.emit_diagnostic(
    OperationFinished({
      kind: self.kind,
      outcome: self.outcome,
      elapsed_ms,
      session_budget: self.session_budget,
    }),
  )
}

///|
// 每个接受的 Session API 调用计一次；内部准备、重试和 DDL 等待不再重复计逻辑操作。
async fn[T] Session::with_operation(
  self : Session,
  kind : OperationKind,
  body : async () -> T,
  outcome? : (T) -> RequestOutcome,
) -> T {
  self.begin_operation()
  let observation = self.config.connection.metrics.map(metrics => {
    OperationObservation::new(metrics, kind)
  })
  defer {
    self.active -= 1
    self.changed.broadcast()
    if observation is Some(observation) {
      observation.finish()
    }
  }
  let result = Ok(body()) catch { error => Err(error) }
  match result {
    Ok(value) => {
      if observation is Some(observation) {
        observation.outcome = match outcome {
          Some(classify) => classify(value)
          None => Succeeded
        }
      }
      value
    }
    Err(error) => {
      if observation is Some(observation) {
        observation.outcome = request_outcome(error)
        observation.session_budget = is_session_budget_error(error)
      }
      raise error
    }
  }
}
