///|
struct Pending {
  reply : @async.Queue[Reply]
  cached : Array[@protocol.Column]
  mut stage : RequestStage
  mut slot_held : Bool
  mut abandoned_at : Int64?
}

///|
fn Connection::fail(self : Connection, error : Error) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  // Windows 上先取消挂起的读取，等读取任务收尾后再关闭句柄。
  if self.reader_active {
    if self.reader_task is Some(task) {
      task.cancel()
    }
  } else {
    self.socket.close()
  }
  if self.reaper_task is Some(task) {
    task.cancel()
  }
  for pending in self.pending.values() {
    pending.reply.close(error~)
    self.release_slot(pending)
  }
  self.abandoned = 0
  self.pending.clear()
}

///|
fn Connection::allocate_stream(self : Connection) -> Int raise DriverError {
  for i = 0; i < 32768; i = i + 1 {
    let id = self.next_stream
    self.next_stream = (id + 1) & 32767
    if !self.pending.contains(id) {
      return id
    }
  }
  raise Unexpected("no free stream id")
}

///|
async fn Connection::exchange(
  self : Connection,
  request : @protocol.Request,
  cached : Array[@protocol.Column],
  context : TimeoutContext,
) -> Reply {
  let queue_until = @async.now() + self.config.queue_timeout_ms.to_int64()
  let mut slot_owned = false
  defer (if slot_owned { self.slots.release() })
  timed(self.config.queue_timeout_ms, Queue, context, () => {
    self.slots.acquire()
    slot_owned = true
  })
  if self.closed {
    raise Closed
  }
  let stream = self.allocate_stream()
  let pending = Pending::{
    reply: @async.Queue(kind=Blocking(1)),
    cached,
    stage: WaitingWriteLock,
    slot_held: true,
    abandoned_at: None,
  }
  slot_owned = false
  self.pending[stream] = pending
  let mut completed = false
  defer (if !completed { self.abandon(stream, pending) })
  context.phase = WaitingWriteLock
  let remaining = (queue_until - @async.now()).to_int()
  let mut lock_owned = false
  defer (if lock_owned { self.mutex.release() })
  timed(remaining, Queue, context, () => {
    self.mutex.acquire()
    lock_owned = true
  })
  // 获取锁后立即注册释放；发送和等待响应共用执行计时。
  let reply = timed(self.config.timeout_ms, Execution, context, () => {
    {
      defer {
        lock_owned = false
        self.mutex.release()
      }
      if self.closed {
        raise Closed
      }
      context.phase = Sending
      self.wire.send(stream, request, on_write=() => {
        context.sent = true
        if pending.stage != Received {
          pending.stage = Sending
        }
      })
      if pending.stage != Received {
        pending.stage = Sent
      }
    }
    context.phase = WaitingResponse
    pending.reply.get()
  })
  completed = true
  reply
}

///|
async fn Connection::receive_loop(self : Connection) -> Unit {
  defer self.socket.close()
  defer self.fail(Closed)
  try {
    while !self.closed {
      let frame = self.wire.receive()
      // 未注册事件订阅，独立的服务端事件不占用请求编号。
      if frame.header.stream == -1 {
        continue
      }
      guard self.pending.get(frame.header.stream) is Some(pending) else {
        raise Unexpected("response for unknown stream")
      }
      let envelope = @protocol.decode_payload(frame)
      let response = @protocol.decode_response(
        frame.header.opcode,
        envelope.message,
        cached=pending.cached,
      )
      self.retire(frame.header.stream, pending)
      pending.stage = Received
      if pending.abandoned_at is Some(_) {
        continue
      }
      let delivered = pending.reply.try_put({
        response,
        warnings: envelope.warnings,
        tracing_id: envelope.tracing_id,
        custom_payload: envelope.custom_payload,
      })
      if !delivered {
        raise Unexpected("duplicate response")
      }
    }
  } catch {
    error => self.fail(error)
  }
}

///|
pub async fn[T] with_connection(
  config? : Config = Config::new(),
  body : async (Connection) -> T,
) -> T {
  @async.with_task_group(group => {
    let connection = connect(group, config~)
    defer connection.close()
    body(connection)
  })
}

///|
pub async fn[T] with_serial_connection(
  config? : Config = Config::new(),
  body : async (Connection) -> T,
) -> T {
  with_connection(config={ ..config, max_in_flight: 1, }, body)
}

///|
pub(all) enum RequestStage {
  WaitingSlot
  WaitingWriteLock
  Sending
  Sent
  Received
} derive(Eq, @debug.Debug)

///|
pub extend RequestStage with Eq::{equal, not_equal}

///|
pub extend RequestStage with @debug.Debug::{to_repr}

///|
fn Connection::release_slot(self : Connection, pending : Pending) -> Unit {
  if pending.slot_held {
    pending.slot_held = false
    self.slots.release()
  }
}

///|
fn Connection::retire(
  self : Connection,
  stream : Int,
  pending : Pending,
) -> Unit {
  self.pending.remove(stream)
  self.release_slot(pending)
  if pending.abandoned_at is Some(_) {
    self.abandoned -= 1
  }
}

///|
fn Connection::abandon(
  self : Connection,
  stream : Int,
  pending : Pending,
) -> Unit {
  if self.closed {
    return
  }
  match pending.stage {
    WaitingSlot | WaitingWriteLock => self.retire(stream, pending)
    Sending => self.fail(Closed)
    Sent => {
      // 完整消息占用编号和在途额度，直至迟到响应或有界回收关闭连接。
      pending.abandoned_at = Some(@async.now())
      pending.reply.close(error=Closed)
      self.abandoned += 1
      if self.abandoned > self.config.max_abandoned {
        self.fail(AbandonedLimitExceeded)
      }
    }
    Received => ()
  }
}

///|
async fn Connection::reap_abandoned(self : Connection) -> Unit {
  let half = self.config.abandoned_timeout_ms / 2
  let interval = if half < 1 { 1 } else if half > 1000 { 1000 } else { half }
  while !self.closed {
    @async.sleep(interval)
    let now = @async.now()
    for pending in self.pending.values() {
      if pending.abandoned_at is Some(since) &&
        now - since >= self.config.abandoned_timeout_ms.to_int64() {
        self.fail(AbandonedRequestExpired)
        return
      }
    }
  }
}
