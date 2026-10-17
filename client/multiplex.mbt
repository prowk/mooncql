///|
struct Pending {
  reply : @async.Queue[Reply]
  cached : Array[@protocol.Column]
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
  for pending in self.pending.values() {
    pending.reply.close(error~)
  }
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
) -> Reply {
  self.slots.acquire()
  defer self.slots.release()
  if self.closed {
    raise Closed
  }
  let stream = self.allocate_stream()
  let pending = Pending::{ reply: @async.Queue(kind=Blocking(1)), cached, }
  self.pending[stream] = pending
  let mut completed = false
  defer {
    self.pending.remove(stream)
    // 已发送或部分发送的请求取消后不能回收编号继续使用这条连接。
    if !completed {
      self.fail(Closed)
    }
  }
  {
    self.mutex.acquire()
    defer self.mutex.release()
    if self.closed {
      raise Closed
    }
    self.socket.write(
      @protocol.encode_frame(stream, request.opcode, request.body),
    )
  }
  let reply = pending.reply.get()
  completed = true
  reply
}

///|
async fn Connection::receive_loop(self : Connection) -> Unit {
  defer self.socket.close()
  defer self.fail(Closed)
  try {
    while !self.closed {
      let frame = read_frame(self.socket, self.config.max_frame_bytes)
      // 未注册事件订阅，独立的服务端事件不占用请求编号。
      if frame.header.stream == -1 {
        continue
      }
      guard self.pending.get(frame.header.stream) is Some(pending) else {
        raise Unexpected("response for unknown stream")
      }
      let envelope = @protocol.decode_envelope(frame)
      let response = @protocol.decode_response(
        frame.header.opcode,
        envelope.message,
        cached=pending.cached,
      )
      self.pending.remove(frame.header.stream)
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
  let connection = connect(config~)
  defer connection.close()
  @async.with_task_group(group => {
    connection.reader_active = true
    connection.reader_task = Some(
      group.spawn(() => connection.receive_loop(), no_wait=true),
    )
    body(connection)
  })
}
