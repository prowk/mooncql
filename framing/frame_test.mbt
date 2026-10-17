///|
test "Cassandra CRC32 seed and little endian golden frames" {
  // CRC32 期望值由 Python zlib 独立生成，帧头按规范计算。
  assert_eq(@framing.crc32(b""), 0x44777ed3U)
  assert_eq(@framing.crc32(b"abc"), 0xc5367a08U)
  assert_eq(@framing.crc32(b"123456789"), 0xe2a261a7U)
  let raw = b"\x03\x00\x02\x42\x96\x7cabc\x08\x7a\x36\xc5"
  assert_eq(@framing.encode(b"abc"), raw)
  assert_eq(@framing.decode(raw).payload, b"abc")
  let compressed = b"\x03\x00\x00\x00\x04\x77\x22\x83abc\x08\x7a\x36\xc5"
  assert_eq(@framing.encode(b"abc", compressed=true), compressed)
  assert_eq(@framing.decode(compressed, compressed=true).payload, b"abc")
  assert_eq(
    @framing.decode(compressed, compressed=true).header.uncompressed_length,
    0,
  )
}

///|
test "frame CRC catches every single byte corruption and truncation" {
  for compressed in [false, true] {
    let bytes = @framing.encode(
      b"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      compressed~,
    )
    for i = 0; i < bytes.length(); i = i + 1 {
      let broken = bytes.to_array()
      broken[i] = (broken[i].to_int() ^ 1).to_byte()
      assert_true(
        try {
          ignore(@framing.decode(Bytes::from_array(broken), compressed~))
          false
        } catch {
          _ => true
        },
      )
      assert_true(
        try {
          ignore(@framing.decode(bytes[0:i].to_owned(), compressed~))
          false
        } catch {
          _ => true
        },
      )
    }
  }
}

///|
test "LZ4 independent block fixture and overlapping match" {
  // 来自 python-lz4 的原始块格式，不含 LZ4 文件头或长度前缀。
  let bytes = b"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let fixture = b"\x1f\x61\x01\x00\x07\x50\x61\x61\x61\x61\x61"
  assert_eq(@framing.lz4_decompress(fixture, 32), bytes)
  assert_eq(@framing.lz4_compress(bytes), fixture)
}

///|
test "LZ4 rejects malformed lengths offsets and expansion" {
  for
    (bytes, expected) in [
      (b"\xf0", 10),
      (b"\x20a", 2),
      (b"\x00\x00\x00", 4),
      (b"\x00\x01\x00", 4),
      (b"\x10a\x01\x00", 4),
      (b"\x10a", 2),
      (b"\x1f\x61\x01\x00\xff\xff", 10),
    ] {
    assert_true(
      try {
        ignore(@framing.lz4_decompress(bytes, expected))
        false
      } catch {
        _ => true
      },
    )
  }
}

///|
test "LZ4 and outer frames cover boundaries incompressible and repeated data" {
  for length in [0, 1, 4, 12, 15, 255, 256, 4096, 131071] {
    for repeated in [false, true] {
      let bytes = Bytes::from_array(
        Array::makei(length, i => {
          (if repeated {
            i % 4
          } else {
            ((i * 73) ^ (i >> 3) ^ (i >> 8)) & 255
          }).to_byte()
        }),
      )
      assert_eq(
        @framing.lz4_decompress(@framing.lz4_compress(bytes), length),
        bytes,
      )
      for compressed in [false, true] {
        let frame = @framing.decode(
          @framing.encode(bytes, compressed~),
          compressed~,
        )
        assert_true(frame.header.self_contained)
        assert_eq(frame.payload, bytes)
      }
    }
  }
}

///|
test "large envelope splits into bounded non self contained frames" {
  let bytes = Bytes::from_array(Array::makei(300000, i => (i % 251).to_byte()))
  let frames = @framing.split(bytes, compressed=true)
  assert_eq(frames.length(), 3)
  let w = @codec.Writer::new()
  for bytes in frames {
    let frame = @framing.decode(bytes, compressed=true)
    assert_true(!frame.header.self_contained)
    assert_true(frame.payload.length() <= 131071)
    w.raw(frame.payload)
  }
  assert_eq(w.to_bytes(), bytes)
  assert_true(
    try {
      ignore(@framing.encode(bytes))
      false
    } catch {
      _ => true
    },
  )
}
