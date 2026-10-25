///|
async test "FIFO mixed sizes across sibling connections cannot bypass oldest waiter" {
  @async.with_timeout(3000, () => {
    @async.with_task_group(group => {
      let config = ConnectionBuilder::new(
        max_in_flight=64,
        max_in_flight_bytes=100,
      )
      let parent = Admission::new(config, session=true)
      let first = Admission::new(config, parent~)
      let second = Admission::new(config, parent~)
      let held = first.register(40L)
      let large = second.register(80L)
      let large_task = group.spawn(() => second.admit(large))
      let smalls = []
      let workers = []
      for index in 0..<32 {
        let small = first.register(1L)
        smalls.push(small)
        workers.push(group.spawn(() => first.admit(small)))
        // 新请求即使能放入剩余字节，也不得越过旧的大请求。
        assert_true(!small.admitted, msg="newcomer \{index}")
        assert_true(!large.admitted)
      }
      assert_eq(parent.waiting, 33)
      assert_eq(parent.waiting_bytes, 112L)
      first.release(held)
      large_task.wait()
      assert_true(large.admitted)
      assert_true(parent.bytes <= 100L)
      // 最早的小请求允许在大请求之后占用剩余容量。
      for index in 0..<20 {
        workers[index].wait()
      }
      assert_eq(parent.bytes, 100L)
      for index in 20..<32 {
        assert_true(!smalls[index].admitted)
      }
      second.release(large)
      for index in 20..<32 {
        workers[index].wait()
      }
      for small in smalls {
        first.release(small)
      }
      assert_eq(parent.waiting, 0)
      assert_eq(parent.waiting_bytes, 0L)
      assert_eq(parent.in_flight, 0)
      assert_eq(parent.bytes, 0L)
      assert_eq(parent.scheduling_snapshot().queued, 0)
      assert_true(parent.scheduling_snapshot().wakeups < 2048L)
      assert_true(parent.scheduling_snapshot().broadcasts < 256L)
    })
  })
}

///|
async test "head timeout and middle cancellation remove FIFO tickets and unblock survivors" {
  @async.with_timeout(3000, () => {
    @async.with_task_group(group => {
      let admission = Admission::new(
        ConnectionBuilder::new(max_in_flight_bytes=100),
      )
      let held = admission.register(40L)
      let old = admission.register(80L)
      let expires = group.spawn(allow_failure=true, () => {
        defer admission.release(old)
        @async.with_timeout(20, () => admission.admit(old))
      })
      let cancelled = admission.register(60L)
      let started : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let cancelled_task = group.spawn(() => {
        defer admission.release(cancelled)
        started.put(())
        admission.admit(cancelled)
      })
      let surviving = admission.register(10L)
      let survivor = group.spawn(() => admission.admit(surviving))
      started.get()
      cancelled_task.cancel()
      ignore(cancelled_task.wait()) catch {
        _ => ()
      }
      ignore(expires.wait()) catch {
        _ => ()
      }
      survivor.wait()
      assert_true(surviving.admitted)
      assert_eq(admission.waiting, 0)
      assert_eq(admission.waiting_bytes, 0L)
      assert_eq(admission.bytes, 50L)
      admission.release(held)
      admission.release(surviving)
      assert_eq(admission.bytes, 0L)
      assert_eq(admission.turns.length(), 0)
    })
  })
}

///|
test "cancel before admit and close release bounded FIFO ownership exactly once" {
  let admission = Admission::new(ConnectionBuilder::new(max_in_flight=1))
  let held = admission.register(9L)
  for _ in 0..<1000 {
    let waiting = admission.register(10L)
    admission.release(waiting)
    admission.release(waiting)
    assert_eq(admission.turns.length(), 0)
    assert_eq(admission.waiting, 0)
    assert_eq(admission.waiting_bytes, 0L)
    assert_eq(admission.in_flight, 1)
  }
  admission.close()
  admission.release(held)
  assert_eq(admission.in_flight, 0)
  assert_eq(admission.bytes, 0L)
}
