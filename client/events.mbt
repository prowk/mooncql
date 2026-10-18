///|
pub async fn Connection::register(
  self : Connection,
  events : Array[@protocol.EventKind],
  deadline? : Deadline,
) -> Unit {
  match self.request(@protocol.register(events), deadline?).response {
    Ready => ()
    Failure(error) => raise Server(error)
    _ => raise Unexpected("expected READY after REGISTER")
  }
}

///|
pub async fn Connection::next_event(self : Connection) -> @protocol.ServerEvent {
  self.events.get()
}

///|
pub fn Connection::dropped_event_count(self : Connection) -> Int64 {
  self.dropped_events
}
