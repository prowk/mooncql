///|
fn occupied_stream(
  admission : Admission,
  abandoned? : Bool = false,
) -> Pending raise DriverError {
  {
    reply: @async.Queue(kind=Blocking(1)),
    cached: [],
    stage: Sent,
    reservation: admission.register(9L),
    abandoned_at: if abandoned {
      Some(0L)
    } else {
      None
    },
    response_bytes: 0L,
  }
}

///|
test "stream allocation wraps 32767 skips active and abandoned IDs and only reuses retired IDs" {
  let admission = Admission::new(Config::new())
  let pending : Map[Int, Pending] = Map([])
  pending[32766] = occupied_stream(admission)
  pending[32767] = occupied_stream(admission, abandoned=true)
  pending[0] = occupied_stream(admission)
  let (id, next) = free_stream(pending, 32766)
  assert_eq(id, 1)
  assert_eq(next, 2)
  pending[id] = occupied_stream(admission)
  let (wrapped, _) = free_stream(pending, 32767)
  assert_eq(wrapped, 2)
  let retained = pending[32767]
  // 尚未排空时，即使等待者已取消，编号也必须保留。
  assert_eq(free_stream(pending, 32767).0, 2)
  pending.remove(32767)
  admission.release(retained.reservation)
  assert_eq(free_stream(pending, 32767), (32767, 0))
  // 新连接代次有自己的编号空间，不被旧连接的废弃编号污染。
  let fresh : Map[Int, Pending] = Map([])
  assert_eq(free_stream(fresh, 32766), (32766, 32767))
  assert_eq(free_stream(fresh, 32767), (32767, 0))
  for item in pending.values() {
    admission.release(item.reservation)
  }
  assert_eq(admission.in_flight, 0)
  assert_eq(admission.bytes, 0L)
}

///|
test "all occupied stream IDs fail without opening real connections" {
  let admission = Admission::new(Config::new())
  let item = occupied_stream(admission)
  let pending : Map[Int, Pending] = Map([])
  for id in 0..<32768 {
    pending[id] = item
  }
  assert_true(
    try {
      ignore(free_stream(pending, 32767))
      false
    } catch {
      Unexpected(_) => true
      _ => false
    },
  )
  admission.release(item.reservation)
}
