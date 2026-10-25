///|
fn make_metrics(
  enabled : Bool,
  recording : Array[Bool],
  samples : Array[String],
) -> @client.Metrics? {
  if !enabled {
    return None
  }
  Some(
    @client.Metrics::with_diagnostics(event => {
      if recording[0] && event is RpcTimeline(timing) {
        let sending = match timing.sending_at_ms {
          Some(time) => time.to_string()
          None => "null"
        }
        let outcome = match timing.outcome {
          Succeeded => "success"
          Timeout(_) => "timeout"
          LocalOverload(_) => "rejected"
          Cancelled => "cancelled"
          _ => "failed"
        }
        samples.push(
          "{\"type\":\"rpc\",\"request_id\":\{timing.request_id},\"queued_at_ms\":\{timing.queued_at_ms},\"sending_at_ms\":\{sending},\"completed_at_ms\":\{timing.completed_at_ms},\"outcome\":\"\{outcome}\"}",
        )
      }
    }),
  )
}
