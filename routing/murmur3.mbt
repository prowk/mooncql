///|
fn rotate(value : UInt64, bits : Int) -> UInt64 {
  (value << bits) | (value >> (64 - bits))
}

///|
fn mix(value : UInt64) -> UInt64 {
  let mut value = value ^ (value >> 33)
  value *= 0xff51afd7ed558ccdUL
  value = value ^ (value >> 33)
  value *= 0xc4ceb9fe1a85ec53UL
  value ^ (value >> 33)
}

///|
fn block(bytes : Bytes, start : Int) -> UInt64 {
  let mut word = 0UL
  for index in 0..<8 {
    word = word | (bytes[start + index].to_int().to_uint64() << (index * 8))
  }
  word
}

///|
pub fn murmur3_token(key : Bytes) -> Int64 {
  if key.is_empty() {
    return -9223372036854775808L
  }
  let c1 = 0x87c37b91114253d5UL
  let c2 = 0x4cf5ad432745937fUL
  let mut h1 = 0UL
  let mut h2 = 0UL
  let count = key.length() / 16
  for index in 0..<count {
    let k1 = rotate(block(key, index * 16) * c1, 31) * c2
    h1 = h1 ^ k1
    h1 = (rotate(h1, 27) + h2) * 5UL + 0x52dce729UL
    let k2 = rotate(block(key, index * 16 + 8) * c2, 33) * c1
    h2 = h2 ^ k2
    h2 = (rotate(h2, 31) + h1) * 5UL + 0x38495ab5UL
  }
  let mut k1 = 0UL
  let mut k2 = 0UL
  let tail = key.length() % 16
  for index in 0..<tail {
    let byte = key[count * 16 + index].to_int()
    // Cassandra 的尾部保留 Java byte 的符号扩展，与通用 Murmur3 的无符号尾部不同。
    let signed = (if byte >= 128 { byte - 256 } else { byte })
      .to_int64()
      .reinterpret_as_uint64()
    if index < 8 {
      k1 = k1 ^ (signed << (index * 8))
    } else {
      k2 = k2 ^ (signed << ((index - 8) * 8))
    }
  }
  if tail > 8 {
    h2 = h2 ^ (rotate(k2 * c2, 33) * c1)
  }
  if tail > 0 {
    h1 = h1 ^ (rotate(k1 * c1, 31) * c2)
  }
  let size = key.length().to_uint64()
  h1 = h1 ^ size
  h2 = h2 ^ size
  h1 += h2
  h2 += h1
  h1 = mix(h1)
  h2 = mix(h2)
  let token = (h1 + h2).reinterpret_as_int64()
  if token == -9223372036854775808L {
    9223372036854775807L
  } else {
    token
  }
}

///|
pub fn routing_key(
  values : Array[@types.Value],
  indices : Array[Int],
) -> Bytes? raise @codec.CodecError {
  if indices.is_empty() {
    return None
  }
  let components = []
  let seen : Map[Int, Bool] = Map([])
  for index in indices {
    if index < 0 || index >= values.length() || seen.contains(index) {
      return None
    }
    seen[index] = true
    match values[index] {
      Null | Unset | Empty => return None
      value => {
        let bytes = @types.encode_value(value)
        if bytes.length() > 65535 {
          return None
        }
        components.push(bytes)
      }
    }
  }
  if components.length() == 1 {
    return Some(components[0])
  }
  let w = @codec.Writer::new()
  let mut total = 0
  for component in components {
    total += component.length() + 3
    if total > 65535 {
      return None
    }
    w.u16(component.length())
    w.raw(component)
    w.u8(0)
  }
  Some(w.to_bytes())
}
