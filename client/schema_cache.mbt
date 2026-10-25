///|
priv struct SchemaCacheEntry {
  identity : Bytes
  epoch : (Int, Int, Int)
  snapshot : SchemaSnapshot
}

///|
struct SchemaCache {
  mutex : @async.Mutex
  mut invalidations : Int
  mut entry : SchemaCacheEntry?
}

///|
fn SchemaCache::new() -> SchemaCache {
  { mutex: @async.Mutex(), invalidations: 0, entry: None, }
}

///|
fn Session::schema_epoch(self : Session) -> (Int, Int, Int) {
  match self.control {
    Some(control) =>
      (self.schema_cache.invalidations, control.schema_epoch, control.refreshes)
    None => (self.schema_cache.invalidations, 0, 0)
  }
}

///|
/// 手动失效只清除缓存；下一次按需请求在同一互斥区内合并读取。
pub fn Session::invalidate_schema(self : Session) -> Unit {
  self.schema_cache.invalidations += 1
  self.schema_cache.entry = None
}

///|
async fn[T] Session::with_schema_lock(
  self : Session,
  deadline : Deadline,
  bytes : Int64,
  body : async () -> T,
) -> T {
  let mutex = self.schema_cache.mutex
  let mut acquired = false
  let mut waiting = false
  defer {
    if acquired {
      mutex.release()
    }
    if waiting {
      self.admission.leave_wait(bytes)
      self.waiting -= 1
      self.waiting_bytes -= bytes
      if self.config.connection.metrics is Some(metrics) {
        metrics.gauges(0L, 0L, -1L, -bytes)
      }
      self.changed.broadcast()
    }
  }
  if mutex.try_acquire() {
    acquired = true
  } else {
    if self.waiting >= self.config.connection.max_waiting {
      raise Overloaded(WaitingQueueFull)
    }
    if bytes >
      self.config.connection.max_waiting_bytes.to_int64() - self.waiting_bytes {
      raise Overloaded(WaitingBytesFull)
    }
    self.admission.enter_wait(bytes)
    self.waiting += 1
    self.waiting_bytes += bytes
    waiting = true
    if self.config.connection.metrics is Some(metrics) {
      metrics.gauges(0L, 0L, 1L, bytes)
    }
    timed_stage(
      deadline.remaining_ms(),
      WaitingSchema,
      Operation,
      { phase: WaitingPrepare, sent: false, },
      () => {
        mutex.acquire()
        acquired = true
      },
    )
  }
  if self.closed {
    raise Closed
  }
  if waiting {
    waiting = false
    self.admission.leave_wait(bytes)
    self.waiting -= 1
    self.waiting_bytes -= bytes
    if self.config.connection.metrics is Some(metrics) {
      metrics.gauges(0L, 0L, -1L, -bytes)
    }
  }
  body()
}

///|
/// 按需读取完整目录；缓存命中仍核对当前协调节点版本，不依赖事件必达。
pub async fn Session::schema_metadata(
  self : Session,
  options? : SchemaOptions,
  deadline? : Deadline,
) -> SchemaSnapshot {
  let options = options.unwrap_or_else(() => SchemaOptions::new())
  let deadline = self.operation_deadline(deadline)
  self.with_operation(SchemaMetadataOperation, () => {
    self.with_schema_lock(deadline, options.identity.length().to_int64(), () => {
      let connection = self.select(
        deadline,
        options.identity.length().to_int64(),
      )
      for _ in 0..<3 {
        let epoch = self.schema_epoch()
        let version = schema_version(connection, deadline) catch {
          error => raise SchemaMetadataError("version", error)
        }
        let stable = epoch == self.schema_epoch() && !connection.closed
        if stable &&
          self.schema_cache.entry is Some(entry) &&
          entry.identity == options.identity &&
          entry.epoch == epoch &&
          entry.snapshot.version == version {
          return entry.snapshot
        }
        self.schema_cache.entry = None
        let snapshot = match
          (Ok(load_schema(connection, version, options, deadline)) catch {
            error => Err(error)
          }) {
          Ok(snapshot) => snapshot
          Err(error) => {
            if connection.closed ||
              (
                error is SchemaMetadataError(_, Server(server)) &&
                server.code == 0x2100
              ) {
              raise error
            }
            let after_failure = schema_version(connection, deadline) catch {
              _ => raise error
            }
            if after_failure != version || epoch != self.schema_epoch() {
              continue
            }
            raise error
          }
        }
        let after = schema_version(connection, deadline) catch {
          error => raise SchemaMetadataError("version", error)
        }
        if self.closed {
          raise Closed
        }
        if after == version &&
          epoch == self.schema_epoch() &&
          !connection.closed {
          self.schema_cache.entry = Some({
            identity: options.identity,
            epoch,
            snapshot,
          })
          return snapshot
        }
      }
      raise SchemaMetadataError(
        "changed",
        Unexpected("schema changed repeatedly while loading metadata"),
      )
    })
  })
}
