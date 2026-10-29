///|
pub(all) suberror ConversionError {
  ConversionError(String)
} derive(@debug.Debug)

///|
pub extend ConversionError with @debug.Debug::{to_repr}

///|
pub struct CqlUuid {
  bytes : Bytes
} derive(Eq, @debug.Debug)

///|
pub extend CqlUuid with Eq::{equal, not_equal}

///|
pub extend CqlUuid with @debug.Debug::{to_repr}

///|
pub fn CqlUuid::from_bytes(bytes : Bytes) -> CqlUuid raise ConversionError {
  if bytes.length() != 16 {
    raise ConversionError("UUID must contain 16 bytes")
  }
  { bytes, }
}

///|
pub fn CqlUuid::from_string(text : String) -> CqlUuid raise ConversionError {
  if text.length() != 36 {
    raise ConversionError("invalid canonical UUID length")
  }
  let parts = text.split("-").to_array()
  if parts.length() != 5 ||
    parts[0].length() != 8 ||
    parts[1].length() != 4 ||
    parts[2].length() != 4 ||
    parts[3].length() != 4 ||
    parts[4].length() != 12 {
    raise ConversionError("invalid canonical UUID groups")
  }
  let digits = parts.map(part => part.to_owned()).join("")
  let bytes = @hex.decode(digits) catch {
    _ => raise ConversionError("invalid UUID hexadecimal digit")
  }
  { bytes, }
}

///|
pub fn CqlUuid::to_bytes(self : CqlUuid) -> Bytes {
  self.bytes
}

///|
pub fn CqlUuid::to_string(self : CqlUuid) -> String {
  let text = @hex.encode(self.bytes)
  "\{text[:8]}-\{text[8:12]}-\{text[12:16]}-\{text[16:20]}-\{text[20:]}"
}

///|
pub fn CqlUuid::to_value(self : CqlUuid) -> Value {
  Uuid(self.bytes)
}

///|
fn conversion_limit(limit : Int32) -> Unit raise ConversionError {
  if limit < 1 || limit > 1000000 {
    raise ConversionError("conversion limit must be between 1 and 1000000")
  }
}

///|
fn zeros(count : Int32) -> String {
  Array::make(count, "0").join("")
}

///|
fn pad(text : String, width : Int32) -> String {
  if text.length() >= width {
    text
  } else {
    zeros(width - text.length()) + text
  }
}

///|
pub struct CqlVarInt {
  bytes : Bytes
} derive(@debug.Debug)

///|
pub extend CqlVarInt with @debug.Debug::{to_repr}

///|
pub fn CqlVarInt::from_bytes(bytes : Bytes) -> CqlVarInt raise ConversionError {
  if bytes.is_empty() {
    raise ConversionError("varint cannot be empty")
  }
  { bytes, }
}

///|
pub fn CqlVarInt::to_bytes(self : CqlVarInt) -> Bytes {
  self.bytes
}

///|
pub fn CqlVarInt::to_value(self : CqlVarInt) -> Value {
  VarInt(self.bytes)
}

///|
pub fn CqlVarInt::from_decimal_string(
  text : String,
  max_digits~ : Int32 = 10000,
) -> CqlVarInt raise ConversionError {
  conversion_limit(max_digits)
  if text.is_empty() || text.length() > max_digits + 1 {
    raise ConversionError("varint text exceeds conversion limit or is empty")
  }
  let data = @utf8.encode(text)
  let negative = data[0] == b'-'
  let mut start = if data[0] == b'-' || data[0] == b'+' { 1 } else { 0 }
  if start == data.length() {
    raise ConversionError("varint requires digits")
  }
  for index in start..<data.length() {
    if data[index] < b'0' || data[index] > b'9' {
      raise ConversionError("invalid varint decimal digit")
    }
  }
  if data.length() - start > max_digits {
    raise ConversionError("varint text exceeds conversion limit")
  }
  while start < data.length() && data[start] == b'0' {
    start += 1
  }
  if start == data.length() {
    return { bytes: b"\x00", }
  }
  let magnitude = [0]
  let mut width = (data.length() - start) % 9
  if width == 0 {
    width = 9
  }
  while start < data.length() {
    let mut group = 0L
    for index in start..<(start + width) {
      group = group * 10L + (data[index].to_int() - 48).to_int64()
    }
    let mut carry = group
    for index in 0..<magnitude.length() {
      let value = magnitude[index].to_int64() * 1000000000L + carry
      magnitude[index] = (value & 255L).to_int()
      carry = value >> 8
    }
    while carry > 0L {
      magnitude.push((carry & 255L).to_int())
      carry = carry >> 8
    }
    start += width
    width = 9
  }
  let bytes = []
  let mut index = magnitude.length() - 1
  while index >= 0 {
    bytes.push(magnitude[index].to_byte())
    index -= 1
  }
  if negative {
    let mut carry = 1
    index = bytes.length() - 1
    while index >= 0 {
      let value = (bytes[index].to_int() ^ 255) + carry
      bytes[index] = (value & 255).to_byte()
      carry = value >> 8
      index -= 1
    }
    if bytes[0].to_int() < 128 {
      bytes.insert(0, b'\xff')
    }
  } else if bytes[0].to_int() >= 128 {
    bytes.insert(0, b'\x00')
  }
  { bytes: Bytes::from_array(bytes), }
}

///|
pub fn CqlVarInt::to_decimal_string(
  self : CqlVarInt,
  max_digits~ : Int32 = 10000,
) -> String raise ConversionError {
  conversion_limit(max_digits)
  let negative = self.bytes[0].to_int() >= 128
  let mut first = 0
  while first + 1 < self.bytes.length() &&
        (
          (self.bytes[first] == b'\x00' && self.bytes[first + 1].to_int() < 128) ||
          (
            self.bytes[first] == b'\xff' &&
            self.bytes[first + 1].to_int() >= 128
          )
        ) {
    first += 1
  }
  // 先去除符号扩展并以保守下界拒绝超大输入，再分配转换工作区。
  if self.bytes.length() - first > max_digits / 2 + 2 {
    raise ConversionError("varint exceeds decimal conversion limit")
  }
  let magnitude = self.bytes[first:].to_array().map(byte => byte.to_int())
  if negative {
    let mut carry = 1
    let mut index = magnitude.length() - 1
    while index >= 0 {
      let value = (magnitude[index] ^ 255) + carry
      magnitude[index] = value & 255
      carry = value >> 8
      index -= 1
    }
  }
  let groups = []
  first = 0
  while first < magnitude.length() && magnitude[first] == 0 {
    first += 1
  }
  while first < magnitude.length() {
    let mut remainder = 0L
    for index in first..<magnitude.length() {
      let value = remainder * 256L + magnitude[index].to_int64()
      magnitude[index] = (value / 1000000000L).to_int()
      remainder = value % 1000000000L
    }
    groups.push(remainder)
    while first < magnitude.length() && magnitude[first] == 0 {
      first += 1
    }
  }
  if groups.is_empty() {
    return "0"
  }
  let parts = []
  let mut index = groups.length() - 1
  while index >= 0 {
    let text = groups[index].to_string()
    parts.push(if index == groups.length() - 1 { text } else { pad(text, 9) })
    index -= 1
  }
  let digits = parts.join("")
  if digits.length() > max_digits {
    raise ConversionError("varint exceeds decimal conversion limit")
  }
  if negative {
    "-" + digits
  } else {
    digits
  }
}

///|
pub struct CqlDecimal {
  scale : Int32
  unscaled : CqlVarInt
} derive(@debug.Debug)

///|
pub extend CqlDecimal with @debug.Debug::{to_repr}

///|
pub fn CqlDecimal::from_parts(
  scale : Int32,
  unscaled : Bytes,
) -> CqlDecimal raise ConversionError {
  { scale, unscaled: CqlVarInt::from_bytes(unscaled), }
}

///|
pub fn CqlDecimal::scale(self : CqlDecimal) -> Int32 {
  self.scale
}

///|
pub fn CqlDecimal::unscaled(self : CqlDecimal) -> CqlVarInt {
  self.unscaled
}

///|
pub fn CqlDecimal::to_value(self : CqlDecimal) -> Value {
  Decimal(self.scale, self.unscaled.bytes)
}

///|
pub fn CqlDecimal::to_scientific_string(
  self : CqlDecimal,
  max_digits~ : Int32 = 10000,
) -> String raise ConversionError {
  let coefficient = self.unscaled.to_decimal_string(max_digits~)
  if self.scale == 0 {
    coefficient
  } else {
    coefficient + "e" + (-self.scale.to_int64()).to_string()
  }
}

///|
pub fn CqlDecimal::to_plain_string(
  self : CqlDecimal,
  max_chars~ : Int32 = 10000,
) -> String raise ConversionError {
  conversion_limit(max_chars)
  let coefficient = self.unscaled.to_decimal_string(max_digits=max_chars)
  let negative = coefficient.has_prefix("-")
  let digits = if negative { coefficient[1:].to_owned() } else { coefficient }
  let sign = if negative { "-" } else { "" }
  let scale = self.scale.to_int64()
  let size = digits.length().to_int64()
  let needed = sign.length().to_int64() +
    (if scale <= 0L {
      size - scale
    } else if scale >= size {
      scale + 2L
    } else {
      size + 1L
    })
  if needed > max_chars.to_int64() {
    raise ConversionError("decimal exceeds plain conversion limit")
  }
  if scale <= 0L {
    sign + digits + zeros((-scale).to_int())
  } else if scale >= size {
    sign + "0." + zeros((scale - size).to_int()) + digits
  } else {
    let point = (size - scale).to_int()
    "\{sign}\{digits[:point]}.\{digits[point:]}"
  }
}

///|
pub fn CqlDecimal::from_string(
  text : String,
  max_digits~ : Int32 = 10000,
) -> CqlDecimal raise ConversionError {
  conversion_limit(max_digits)
  if text.is_empty() || text.length() > max_digits + 32 {
    raise ConversionError("decimal text exceeds conversion limit or is empty")
  }
  let data = @utf8.encode(text)
  let negative = data[0] == b'-'
  let mut index = if data[0] == b'-' || data[0] == b'+' { 1 } else { 0 }
  let digits = []
  let mut fraction = 0
  let mut point = false
  while index < data.length() && data[index] != b'e' && data[index] != b'E' {
    let byte = data[index]
    if byte == b'.' && !point {
      point = true
    } else if byte >= b'0' && byte <= b'9' {
      digits.push(byte)
      if point {
        fraction += 1
      }
    } else {
      raise ConversionError("invalid decimal coefficient")
    }
    index += 1
  }
  if digits.is_empty() || digits.length() > max_digits {
    raise ConversionError("invalid decimal digit count")
  }
  let mut exponent = 0L
  if index < data.length() {
    index += 1
    let exponent_negative = index < data.length() && data[index] == b'-'
    if index < data.length() && (data[index] == b'-' || data[index] == b'+') {
      index += 1
    }
    if index == data.length() {
      raise ConversionError("decimal exponent requires digits")
    }
    for byte in data[index:] {
      if byte < b'0' || byte > b'9' {
        raise ConversionError("invalid decimal exponent")
      }
      if exponent > 100000000000L {
        raise ConversionError("decimal exponent out of range")
      }
      exponent = exponent * 10L + (byte.to_int() - 48).to_int64()
    }
    if exponent_negative {
      exponent = -exponent
    }
  }
  let scale = fraction.to_int64() - exponent
  if scale < -2147483648L || scale > 2147483647L {
    raise ConversionError("decimal scale out of range")
  }
  let digit_text = @utf8.decode(Bytes::from_array(digits)) catch {
    _ => raise ConversionError("invalid decimal digits")
  }
  let coefficient = (if negative { "-" } else { "" }) + digit_text
  {
    scale: scale.to_int(),
    unscaled: CqlVarInt::from_decimal_string(coefficient, max_digits~),
  }
}
