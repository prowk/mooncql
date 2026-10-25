///|
struct Pending {
  reply : @async.Queue[Reply]
  cached : Array[@protocol.Column]
  mut stage : RequestStage
  reservation : Reservation
  mut abandoned_at : Int64?
  mut response_bytes : Int64
}

///|
fn Connection::fail(self : Connection, error : Error) -> Unit {
  if self.closed {
    return
  }
  if self.draining && self.drain_outcome is None {
    self.drain_outcome = Some(Interrupted(self.drain_remaining()))
  }
  self.closed = true
  self.wire.messages.clear()
  self.wire.position = 0
  self.wire.queued_bytes = 0L
  self.wire.decoder.clear()
  if self.reader_active && self.config.metrics is Some(metrics) {
    metrics.data.connections_closed += 1L
    metrics.emit(
      ConnectionClosed(
        Endpoint::new(host=self.config.host, port=self.config.port),
      ),
    )
  }
  self.failure = Some(error)
  self.closed_changed.broadcast()
  self.admission.close()
  self.events.close(error~)
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
  if self.health_task is Some(task) {
    task.cancel()
  }
  for pending in self.pending.values() {
    pending.reply.close(error~)
    self.release_resources(pending)
  }
  self.abandoned = 0
  self.pending.clear()
  // 断开缓存到 Prepared 再到 Connection 的引用环，旧代次不积累缓存。
  self.prepared_cache.clear()
  self.preparing.clear()
  self.preparing_bytes = 0L
}

///|
fn Connection::allocate_stream(self : Connection) -> Int raise DriverError {
  let (id, next) = free_stream(self.pending, self.next_stream)
  self.next_stream = next
  id
}

///|
fn free_stream(
  pending : Map[Int, Pending],
  start : Int,
) -> (Int, Int) raise DriverError {
  let mut next = start & 32767
  for i = 0; i < 32768; i = i + 1 {
    let id = next
    next = (id + 1) & 32767
    if !pending.contains(id) {
      return (id, next)
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
  reservation : Reservation,
  observation : RequestObservation?,
) -> Reply {
  let queue_until = @async.now() + self.config.queue_timeout_ms.to_int64()
  timed(self.config.queue_timeout_ms, Queue, context, () => {
    self.admission.admit(reservation)
  })
  if self.closed {
    raise Closed
  }
  let stream = self.allocate_stream()
  let pending = Pending::{
    reply: @async.Queue(kind=Blocking(1)),
    cached,
    stage: WaitingWriteLock,
    reservation,
    abandoned_at: None,
    response_bytes: 0L,
  }
  reservation.owned_by_pending = true
  defer self.release_delivery(pending)
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
  if observation is Some(observation) {
    observation.executing = Some(@async.now())
  }
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
        if observation is Some(observation) && observation.sending is None {
          observation.sending = Some(@async.now())
        }
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
      self.last_received = @async.now()
      if frame.header.opcode == 12 {
        if frame.header.stream != -1 {
          raise Unexpected("EVENT must use stream -1")
        }
        let payload = @protocol.decode_payload(frame)
        let event = @protocol.decode_event(payload.message)
        // 接收任务不等待慢消费者；丢失计数提示控制连接刷新完整快照。
        if !self.events.try_put(event) {
          self.dropped_events += 1L
        }
        continue
      }
      if frame.header.stream < 0 {
        raise Unexpected("only EVENT may use a negative stream")
      }
      guard self.pending.get(frame.header.stream) is Some(pending) else {
        raise Unexpected("response for unknown stream")
      }
      if pending.abandoned_at is Some(_) {
        // Wire 已验证完整帧 CRC、边界、方向和 stream；废弃正文不再解释。
        // 元数据、警告和 Value 都不得被迟到结果更新，也不构造调用方不可见的页。
        if ![0, 2, 3, 6, 8, 14, 16].contains(frame.header.opcode) {
          raise Unexpected("unexpected abandoned response opcode")
        }
        self.retire(frame.header.stream, pending)
        pending.stage = Received
        self.discarded_responses += 1L
        continue
      }
      pending.response_bytes = frame.body.length().to_int64()
      self.delivery_bytes += pending.response_bytes
      if self.delivery_bytes > self.peak_delivery_bytes {
        self.peak_delivery_bytes = self.delivery_bytes
      }
      let decoding_started = @async.now()
      let envelope = @protocol.decode_payload(frame)
      let response = @protocol.decode_response_limited(
        frame.header.opcode,
        envelope.message,
        cached=pending.cached,
        max_rows=self.response_limits.rows,
        max_columns=self.response_limits.columns,
        max_value_nodes=self.response_limits.value_nodes,
        max_depth=self.response_limits.depth,
      )
      let decoding_ms = @async.now() - decoding_started
      self.decode_ms += decoding_ms
      if decoding_ms > self.max_decode_ms {
        self.max_decode_ms = decoding_ms
      }
      self.decoded_responses += 1L
      self.retire(frame.header.stream, pending)
      pending.stage = Received
      let delivered = pending.reply.try_put({
        response,
        warnings: envelope.warnings,
        tracing_id: envelope.tracing_id,
        custom_payload: envelope.custom_payload,
        coordinator: Endpoint::new(host=self.config.host, port=self.config.port),
        attempt_count: 1,
        previous: [],
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
pub async fn[T] with_connection_builder(
  config? : ConnectionBuilder = ConnectionBuilder::new(),
  response_limits? : ResponseLimits,
  body : async (Connection) -> T,
) -> T {
  @async.with_task_group(group => {
    let connection = connect_builder(group, config~, response_limits?)
    defer connection.close()
    body(connection)
  })
}

///|
pub async fn[T] with_serial_connection_builder(
  config? : ConnectionBuilder = ConnectionBuilder::new(),
  response_limits? : ResponseLimits,
  body : async (Connection) -> T,
) -> T {
  with_connection_builder(
    config={ ..config, max_in_flight: 1, },
    response_limits?,
    body,
  )
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
fn Connection::release_resources(self : Connection, pending : Pending) -> Unit {
  self.admission.release(pending.reservation)
}

///|
fn Connection::retire(
  self : Connection,
  stream : Int,
  pending : Pending,
) -> Unit {
  self.pending.remove(stream)
  self.release_resources(pending)
  self.closed_changed.broadcast()
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
