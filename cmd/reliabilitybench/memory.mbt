///|
fn receive_note(connection : @client.Connection) -> Unit raise {
  let memory = connection.receive_memory()
  assert_eq(memory.delivering_body_bytes, 0L)
  assert_eq(memory.queued_envelope_bytes, 0L)
  assert_eq(memory.reassembling_bytes, 0L)
  println(
    "{\"type\":\"memory\",\"peak_wire_bytes\":\{memory.peak_wire_bytes},\"peak_delivering_body_bytes\":\{memory.peak_delivering_body_bytes},\"decoded_responses\":\{memory.decoded_responses},\"discarded_responses\":\{memory.discarded_responses},\"decode_ms\":\{memory.decode_ms},\"max_decode_ms\":\{memory.max_decode_ms}}",
  )
}
