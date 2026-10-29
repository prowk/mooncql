///|
pub(all) struct Header {
  payload_length : Int32
  uncompressed_length : Int32
  self_contained : Bool
}

///|
pub(all) struct Frame {
  header : Header
  payload : Bytes
}

///|
fn little(bytes : Bytes) -> Int64 {
  let mut value = 0L
  for i, byte in bytes {
    value = value | (byte.to_int().to_int64() << (8 * i))
  }
  value
}

///|
fn write_little(w : @codec.Writer, value : Int64, count : Int32) -> Unit {
  for i = 0; i < count; i = i + 1 {
    w.u8((value >> (8 * i)).to_int())
  }
}

///|
pub fn decode_header(
  bytes : Bytes,
  compressed~ : Bool = false,
) -> Header raise @codec.CodecError {
  let width = if compressed { 5 } else { 3 }
  if bytes.length() != width + 3 {
    raise @codec.CodecError("invalid v5 frame header size")
  }
  let fields = bytes[0:width].to_owned()
  if crc24(fields) != little(bytes[width:].to_owned()).to_int() {
    raise @codec.CodecError("v5 frame header CRC24 mismatch")
  }
  let value = little(fields)
  {
    payload_length: (value & 0x1ffffL).to_int(),
    uncompressed_length: if compressed {
      ((value >> 17) & 0x1ffffL).to_int()
    } else {
      0
    },
    self_contained: (value & (1L << (if compressed { 34 } else { 17 }))) != 0L,
  }
}

///|
pub fn decode_payload(
  header : Header,
  bytes : Bytes,
) -> Frame raise @codec.CodecError {
  if header.payload_length < 0 ||
    header.payload_length > 131071 ||
    header.uncompressed_length < 0 ||
    header.uncompressed_length > 131071 ||
    bytes.length() != header.payload_length + 4 {
    raise @codec.CodecError("invalid v5 frame payload size")
  }
  let payload = bytes[0:header.payload_length].to_owned()
  if crc32(payload).to_int64() !=
    little(bytes[header.payload_length:].to_owned()) {
    raise @codec.CodecError("v5 frame payload CRC32 mismatch")
  }
  {
    header,
    payload: if header.uncompressed_length == 0 {
      payload
    } else {
      lz4_decompress(payload, header.uncompressed_length)
    },
  }
}

///|
pub fn decode(
  bytes : Bytes,
  compressed~ : Bool = false,
) -> Frame raise @codec.CodecError {
  let r = @codec.Reader::new(bytes)
  let header = decode_header(
    r.take(if compressed { 8 } else { 6 }),
    compressed~,
  )
  decode_payload(header, r.take(r.remaining()))
}

///|
pub fn encode(
  payload : Bytes,
  self_contained~ : Bool = true,
  compressed~ : Bool = false,
) -> Bytes raise @codec.CodecError {
  if payload.length() > 131071 {
    raise @codec.CodecError("v5 frame payload exceeds 128 KiB limit")
  }
  let candidate = if compressed { lz4_compress(payload) } else { payload }
  let use_compression = compressed && candidate.length() < payload.length()
  let wire = if use_compression { candidate } else { payload }
  let value = wire.length().to_int64() |
    (if use_compression { payload.length().to_int64() << 17 } else { 0L }) |
    (if self_contained { 1L << (if compressed { 34 } else { 17 }) } else { 0L })
  let fields = @codec.Writer::new()
  write_little(fields, value, if compressed { 5 } else { 3 })
  let header = fields.to_bytes()
  let w = @codec.Writer::new()
  w.raw(header)
  write_little(w, crc24(header).to_int64(), 3)
  w.raw(wire)
  write_little(w, crc32(wire).to_int64(), 4)
  w.to_bytes()
}

///|
pub fn split(
  envelope : Bytes,
  compressed~ : Bool = false,
) -> Array[Bytes] raise @codec.CodecError {
  let frames = []
  let mut offset = 0
  while offset < envelope.length() {
    let remaining = envelope.length() - offset
    let length = if remaining > 131071 { 131071 } else { remaining }
    frames.push(
      encode(
        envelope[offset:offset + length].to_owned(),
        self_contained=envelope.length() <= 131071,
        compressed~,
      ),
    )
    offset += length
  }
  frames
}
