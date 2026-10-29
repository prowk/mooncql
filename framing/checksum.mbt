///|
pub fn crc24(bytes : Bytes) -> Int32 {
  let mut crc = 0x875060
  for byte in bytes {
    crc = crc ^ (byte.to_int() << 16)
    for bit = 0; bit < 8; bit = bit + 1 {
      crc = crc << 1
      if (crc & 0x1000000) != 0 {
        crc = crc ^ 0x1974F0B
      }
    }
  }
  crc
}

///|
let crc32_table : Array[UInt32] = Array::makei(256, index => {
  let mut value = index.reinterpret_as_uint()
  for bit = 0; bit < 8; bit = bit + 1 {
    value = if (value & 1U) != 0U {
      (value >> 1) ^ 0xEDB88320U
    } else {
      value >> 1
    }
  }
  value
})

///|
pub fn crc32(bytes : Bytes) -> UInt32 {
  let mut crc = 0xFFFFFFFFU
  // Cassandra 在每个载荷前先输入固定的四字节种子。
  for byte in b"\xfa\x2d\x55\xca" {
    crc = (crc >> 8) ^
      crc32_table[((crc ^ byte.to_int().reinterpret_as_uint()) & 255U).reinterpret_as_int()]
  }
  for byte in bytes {
    crc = (crc >> 8) ^
      crc32_table[((crc ^ byte.to_int().reinterpret_as_uint()) & 255U).reinterpret_as_int()]
  }
  crc ^ 0xFFFFFFFFU
}
