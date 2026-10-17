///|
pub(all) struct EnvelopeHeader {
  response : Bool
  flags : Int
  stream : Int
  opcode : Int
  length : Int
} derive(Eq, @debug.Debug)

///|
pub(all) struct MessageEnvelope {
  header : EnvelopeHeader
  body : Bytes
} derive(Eq, @debug.Debug)

///|
pub fn decode_envelope_header(
  bytes : Bytes,
  max_body? : Int = 16777216,
) -> EnvelopeHeader raise @codec.CodecError {
  let r = @codec.Reader::new(bytes)
  let version = r.u8()
  if version != 0x05 && version != 0x85 {
    raise @codec.CodecError("expected native protocol v5")
  }
  let flags = r.u8()
  let unsigned_stream = r.u16()
  let stream = if unsigned_stream >= 32768 {
    unsigned_stream - 65536
  } else {
    unsigned_stream
  }
  let opcode = r.u8()
  let length = r.i32()
  r.finish()
  if length < 0 || max_body < 0 || length > max_body {
    raise @codec.CodecError("frame body exceeds configured limit")
  }
  if stream < 0 && (version != 0x85 || stream != -1 || opcode != 0x0C) {
    raise @codec.CodecError("invalid server event stream")
  }
  { response: version == 0x85, flags, stream, opcode, length, }
}

///|
pub fn encode_envelope(
  stream : Int,
  opcode : Int,
  body : Bytes,
  response? : Bool = false,
  flags? : Int = 0,
) -> Bytes raise @codec.CodecError {
  if stream < -1 ||
    stream > 32767 ||
    (stream == -1 && (!response || opcode != 0x0C)) {
    raise @codec.CodecError("invalid stream id")
  }
  if opcode < 0 || opcode > 255 || flags < 0 || flags > 255 {
    raise @codec.CodecError("invalid opcode or unsupported flags")
  }
  let w = @codec.Writer::new()
  w.u8(if response { 0x85 } else { 0x05 })
  w.u8(flags)
  w.u16(if stream < 0 { stream + 65536 } else { stream })
  w.u8(opcode)
  w.i32(body.length())
  w.raw(body)
  w.to_bytes()
}

///|
pub fn decode_message_envelope(
  bytes : Bytes,
  max_body? : Int = 16777216,
) -> MessageEnvelope raise @codec.CodecError {
  let r = @codec.Reader::new(bytes)
  let header = decode_envelope_header(r.take(9), max_body~)
  let body = r.take(header.length)
  r.finish()
  { header, body, }
}

///|
pub(all) struct MessagePayload {
  tracing_id : Bytes?
  warnings : Array[String]
  custom_payload : Map[String, Bytes?]
  message : Bytes
} derive(@debug.Debug)

///|
pub fn decode_payload(
  frame : MessageEnvelope,
) -> MessagePayload raise @codec.CodecError {
  let r = @codec.Reader::new(frame.body)
  let tracing_id = if (frame.header.flags & 2) != 0 {
    Some(r.take(16))
  } else {
    None
  }
  let warnings = []
  if (frame.header.flags & 8) != 0 {
    let count = r.u16()
    for i = 0; i < count; i = i + 1 {
      warnings.push(r.string())
    }
  }
  let custom_payload : Map[String, Bytes?] = Map([])
  if (frame.header.flags & 4) != 0 {
    let count = r.u16()
    for i = 0; i < count; i = i + 1 {
      let key = r.string()
      custom_payload[key] = r.bytes()
    }
  }
  { tracing_id, warnings, custom_payload, message: r.take(r.remaining()), }
}

///|
pub extend EnvelopeHeader with Eq::{equal, not_equal}

///|
pub extend EnvelopeHeader with @debug.Debug::{to_repr}

///|
pub extend MessageEnvelope with Eq::{equal, not_equal}

///|
pub extend MessageEnvelope with @debug.Debug::{to_repr}

///|
pub extend MessagePayload with @debug.Debug::{to_repr}
