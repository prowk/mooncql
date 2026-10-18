///|
pub(all) enum NodeState {
  Connecting
  Ready
  Backoff
  Stopped
} derive(Eq, @debug.Debug)

///|
pub extend NodeState with Eq::{equal, not_equal}

///|
pub extend NodeState with @debug.Debug::{to_repr}

///|
pub(all) struct SessionConfig {
  connection : Config
  backoff_initial_ms : Int
  backoff_max_ms : Int
  jitter : Double
  stable_reset_ms : Int
}

///|
pub fn SessionConfig::new(
  connection? : Config = Config::new(),
  backoff_initial_ms? : Int = 25,
  backoff_max_ms? : Int = 2000,
  jitter? : Double = 0.2,
  stable_reset_ms? : Int = 1000,
) -> SessionConfig {
  { connection, backoff_initial_ms, backoff_max_ms, jitter, stable_reset_ms, }
}

///|
pub(all) struct NodeStatus {
  state : NodeState
  generation : Int
  attempts : Int
}

///|
pub struct Session {
  config : SessionConfig
  changed : @async.CondVar
  mut current : Connection?
  mut worker : @async.Task[Unit]?
  mut closed : Bool
  mut state : NodeState
  mut generation : Int
  mut attempts : Int
  mut last_error : Error?
  mut active : Int
  mut waiting : Int
  mut waiting_bytes : Int64
}

///|
pub async fn[T] with_session(
  config? : SessionConfig = SessionConfig::new(),
  body : async (Session) -> T,
) -> T {
  config.connection.validate()
  if config.backoff_initial_ms < 1 ||
    config.backoff_max_ms < config.backoff_initial_ms ||
    config.stable_reset_ms < 0 ||
    !(config.jitter >= 0.0 && config.jitter <= 1.0) {
    raise Configuration("invalid session backoff configuration")
  }
  @async.with_task_group(group => {
    let session = Session::{
      config,
      changed: @async.CondVar::Cond(),
      current: None,
      worker: None,
      closed: false,
      state: Connecting,
      generation: 0,
      attempts: 0,
      last_error: None,
      active: 0,
      waiting: 0,
      waiting_bytes: 0L,
    }
    defer session.stop()
    session.worker = Some(
      group.spawn(() => session.maintain(group), no_wait=true),
    )
    body(session)
  })
}

///|
fn Session::stop(self : Session) -> Unit {
  if !self.closed {
    self.closed = true
    if self.current is Some(connection) {
      connection.close()
    }
    if self.worker is Some(task) {
      task.cancel()
    }
    self.changed.broadcast()
  }
}

///|
pub async fn Session::close(self : Session) -> Unit {
  self.stop()
  if self.worker is Some(task) {
    ignore(task.wait()) catch {
      _ => ()
    }
  }
  while self.active > 0 {
    self.changed.wait()
  }
}

///|
pub fn Session::is_closed(self : Session) -> Bool {
  self.closed
}

///|
pub fn Session::status(self : Session) -> NodeStatus {
  { state: self.state, generation: self.generation, attempts: self.attempts, }
}

///|
pub fn Session::last_error(self : Session) -> Error? {
  self.last_error
}

///|
pub fn Session::waiting_count(self : Session) -> Int {
  self.waiting
}

///|
pub fn Session::active_count(self : Session) -> Int {
  self.active
}

///|
async fn[G] Session::maintain(
  self : Session,
  group : @async.TaskGroup[G],
) -> Unit {
  defer {
    self.state = Stopped
    self.changed.broadcast()
  }
  let random = @random.Rand::new()
  let mut backoff = self.config.backoff_initial_ms
  while !self.closed {
    self.state = Connecting
    self.attempts += 1
    self.changed.broadcast()
    let connection = Some(connect(group, config=self.config.connection)) catch {
      error => {
        self.last_error = Some(error)
        None
      }
    }
    if connection is Some(connection) {
      let since = @async.now()
      {
        self.current = Some(connection)
        self.generation += 1
        connection.generation = self.generation
        self.state = Ready
        self.last_error = None
        self.changed.broadcast()
        // 即使维护任务被取消，也等待该连接的读任务与回收任务结束。
        defer @async.protect_from_cancel(() => {
          connection.shutdown()
          self.current = None
          self.changed.broadcast()
        })
        connection.wait_closed()
        self.last_error = connection.failure
      }
      if @async.now() - since >= self.config.stable_reset_ms.to_int64() {
        backoff = self.config.backoff_initial_ms
      }
    }
    if self.closed {
      return
    }
    self.state = Backoff
    self.changed.broadcast()
    let candidate = backoff.to_double() *
      (1.0 - self.config.jitter + 2.0 * self.config.jitter * random.double())
    let delay = if candidate < 1.0 {
      1
    } else if candidate > self.config.backoff_max_ms.to_double() {
      self.config.backoff_max_ms
    } else {
      candidate.to_int()
    }
    @async.sleep(delay)
    backoff = if backoff > self.config.backoff_max_ms / 2 {
      self.config.backoff_max_ms
    } else {
      backoff * 2
    }
  }
}

///|
async fn Session::select(
  self : Session,
  deadline : Deadline,
  bytes : Int64,
) -> Connection {
  if self.closed {
    raise Closed
  }
  if self.current is Some(connection) && !connection.is_closed() {
    return connection
  }
  if self.waiting >= self.config.connection.max_waiting {
    raise Overloaded(WaitingQueueFull)
  }
  if self.waiting_bytes + bytes >
    self.config.connection.max_waiting_bytes.to_int64() {
    raise Overloaded(WaitingBytesFull)
  }
  self.waiting += 1
  self.waiting_bytes += bytes
  defer {
    self.waiting -= 1
    self.waiting_bytes -= bytes
    self.changed.broadcast()
  }
  timed(
    deadline.remaining_ms(),
    Operation,
    { phase: WaitingConnection, sent: false, },
    () => {
      while !self.closed {
        if self.current is Some(connection) && !connection.is_closed() {
          return connection
        }
        self.changed.wait()
      }
      raise Closed
    },
  )
}

///|
fn Session::operation_deadline(
  self : Session,
  deadline : Deadline?,
) -> Deadline raise DriverError {
  match deadline {
    Some(deadline) => deadline
    None => Deadline::after(self.config.connection.operation_timeout_ms)
  }
}

///|
pub async fn Session::request(
  self : Session,
  request : @protocol.Request,
  deadline? : Deadline,
) -> Reply {
  let deadline = self.operation_deadline(deadline)
  if request.body.length() > self.config.connection.max_frame_bytes {
    raise Configuration("request exceeds frame limit")
  }
  self.active += 1
  defer {
    self.active -= 1
    self.changed.broadcast()
  }
  let connection = self.select(deadline, request.body.length().to_int64() + 9L)
  // 只选择一次连接；断线失败直接交给调用方，不重新执行未知结果的请求。
  connection.request(request, deadline~)
}

///|
pub async fn Session::query(
  self : Session,
  cql : String,
  values? : Array[@types.Value] = [],
  options? : @protocol.QueryOptions = @protocol.QueryOptions::new(),
  deadline? : Deadline,
) -> @protocol.ResultSet {
  let deadline = self.operation_deadline(deadline)
  match
    self.request(@protocol.query(cql, values~, options~), deadline~).response {
    Result(result) => result
    Failure(error) => raise Server(error)
    _ => raise Unexpected("expected RESULT response")
  }
}
