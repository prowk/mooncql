///|
async fn Connection::maintain_health(self : Connection) -> Unit {
  let interval = self.config.heartbeat_interval_ms
  let tick = if interval < 1000 { interval } else { 1000 }
  while !self.closed && !self.draining {
    @async.sleep(tick)
    // 只探测空闲连接，业务请求和废弃请求仍由各自的期限约束。
    if self.closed ||
      self.draining ||
      !self.pending.is_empty() ||
      self.admission.waiting > 0 ||
      !self.admission.fits(9L) ||
      @async.now() - self.last_received < interval.to_int64() {
      continue
    }
    let healthy = try {
      let reply = self.request_measured(
        @protocol.options(),
        [],
        Some(Deadline::after(self.config.heartbeat_timeout_ms)),
        Heartbeat,
      )
      reply.response is Supported(options) && options.contains("CQL_VERSION")
    } catch {
      _ => false
    }
    if !healthy && !self.closed && !self.draining {
      // OPTIONS 不执行应用语句；失败只回收连接，由 Session 独立重连。
      self.fail(HeartbeatFailed)
    }
  }
}
