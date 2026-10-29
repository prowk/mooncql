///|
pub(all) struct RequestOptions {
  tracing : Bool
  custom_payload : Map[String, Bytes?]
} derive(@debug.Debug)

///|
pub extend RequestOptions with @debug.Debug::{to_repr}

///|
pub fn RequestOptions::new(
  tracing~ : Bool = false,
  custom_payload~ : Map[String, Bytes?] = Map([]),
) -> RequestOptions {
  { tracing, custom_payload, }.snapshot()
}

///|
pub fn RequestOptions::snapshot(self : RequestOptions) -> RequestOptions {
  let payload : Map[String, Bytes?] = Map([])
  for key, value in self.custom_payload {
    payload[key] = value
  }
  { ..self, custom_payload: payload, }
}

///|
pub fn Request::with_options(
  self : Request,
  options : RequestOptions,
) -> Request raise @codec.CodecError {
  if self.flags != 0 {
    raise @codec.CodecError("request already carries envelope flags")
  }
  if self.opcode != 7 &&
    self.opcode != 9 &&
    self.opcode != 10 &&
    self.opcode != 13 {
    raise @codec.CodecError("request type does not support query extensions")
  }
  if options.custom_payload.length() > 65535 {
    raise @codec.CodecError("too many custom payload entries")
  }
  let flags = (if options.tracing { 2 } else { 0 }) |
    (if options.custom_payload.is_empty() { 0 } else { 4 })
  if options.custom_payload.is_empty() {
    return { ..self, flags, }
  }
  let w = @codec.Writer::new()
  w.u16(options.custom_payload.length())
  let keys = options.custom_payload.keys().to_array()
  keys.sort()
  for key in keys {
    w.string(key)
    w.bytes(options.custom_payload[key])
  }
  w.raw(self.body)
  { ..self, flags, body: w.to_bytes(), }
}

///|
fn decorate(
  request : Request,
  options : RequestOptions?,
) -> Request raise @codec.CodecError {
  match options {
    Some(options) => request.with_options(options)
    None => request
  }
}
