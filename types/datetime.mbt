///|
fn floor_div(value : Int64, divisor : Int64) -> Int64 {
  let quotient = value / divisor
  if value % divisor < 0L {
    quotient - 1L
  } else {
    quotient
  }
}

///|
fn leap_year(year : Int64) -> Bool {
  year % 4L == 0L && (year % 100L != 0L || year % 400L == 0L)
}

///|
fn civil_days(
  year : Int64,
  month : Int32,
  day : Int32,
) -> Int64 raise ConversionError {
  if year < -1000000000L || year > 1000000000L || month < 1 || month > 12 {
    raise ConversionError("calendar year or month out of range")
  }
  let length = match month {
    2 => if leap_year(year) { 29 } else { 28 }
    4 | 6 | 9 | 11 => 30
    _ => 31
  }
  if day < 1 || day > length {
    raise ConversionError("calendar day out of range")
  }
  let year = year - (if month <= 2 { 1L } else { 0L })
  let era = floor_div(year, 400L)
  let yoe = year - era * 400L
  let adjusted = month + (if month > 2 { -3 } else { 9 })
  let doy = (153L * adjusted.to_int64() + 2L) / 5L + day.to_int64() - 1L
  era * 146097L + yoe * 365L + yoe / 4L - yoe / 100L + doy - 719468L
}

///|
fn civil_parts(days : Int64) -> (Int64, Int32, Int32) {
  let z = days + 719468L
  let era = floor_div(z, 146097L)
  let doe = z - era * 146097L
  let yoe = (doe - doe / 1460L + doe / 36524L - doe / 146096L) / 365L
  let year = yoe + era * 400L
  let doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
  let mp = (5L * doy + 2L) / 153L
  let day = doy - (153L * mp + 2L) / 5L + 1L
  let month = mp + (if mp < 10L { 3L } else { -9L })
  (year + (if month <= 2L { 1L } else { 0L }), month.to_int(), day.to_int())
}

///|
fn date_string(days : Int64) -> String {
  let (year, month, day) = civil_parts(days)
  let y = if year >= 0L && year <= 9999L {
    pad(year.to_string(), 4)
  } else if year < 0L {
    "-" + pad((-year).to_string(), 6)
  } else {
    "+" + pad(year.to_string(), 6)
  }
  "\{y}-\{pad(month.to_string(), 2)}-\{pad(day.to_string(), 2)}"
}

///|
fn decimal_digits(
  data : Bytes,
  start : Int32,
  end : Int32,
) -> Int64 raise ConversionError {
  if start < 0 || end > data.length() || start >= end || end - start > 12 {
    raise ConversionError("invalid date/time digits")
  }
  let mut value = 0L
  for i in start..<end {
    if data[i] < b'0' || data[i] > b'9' {
      raise ConversionError("invalid date/time digit")
    }
    value = value * 10L + (data[i].to_int() - 48).to_int64()
  }
  value
}

///|
fn parse_date(text : String) -> Int64 raise ConversionError {
  let data = @utf8.encode(text)
  if data.length() < 10 || data.length() > 20 {
    raise ConversionError("invalid date length")
  }
  let end_year = data.length() - 6
  if data[end_year] != b'-' || data[end_year + 3] != b'-' {
    raise ConversionError("expected YYYY-MM-DD")
  }
  let signed = data[0] == b'-' || data[0] == b'+'
  if (!signed && end_year != 4) || (signed && end_year < 7) {
    raise ConversionError("extended year requires sign and at least six digits")
  }
  let year = decimal_digits(data, if signed { 1 } else { 0 }, end_year)
  civil_days(
    if data[0] == b'-' {
      -year
    } else {
      year
    },
    decimal_digits(data, end_year + 1, end_year + 3).to_int(),
    decimal_digits(data, end_year + 4, data.length()).to_int(),
  )
}

///|
pub struct CqlDate {
  days : Int32
} derive(Eq, @debug.Debug)

///|
pub extend CqlDate with Eq::{equal, not_equal}

///|
pub extend CqlDate with @debug.Debug::{to_repr}

///|
pub fn CqlDate::from_days(days : Int32) -> CqlDate {
  { days, }
}

///|
pub fn CqlDate::days(self : CqlDate) -> Int32 {
  self.days
}

///|
pub fn CqlDate::to_value(self : CqlDate) -> Value {
  Date(self.days)
}

///|
pub fn CqlDate::to_string(self : CqlDate) -> String {
  date_string(self.days.to_int64())
}

///|
pub fn CqlDate::from_string(text : String) -> CqlDate raise ConversionError {
  let days = parse_date(text)
  if days < -2147483648L || days > 2147483647L {
    raise ConversionError("date outside CQL day range")
  }
  { days: days.to_int(), }
}

///|
pub struct CqlTime {
  nanos : Int64
} derive(Eq, @debug.Debug)

///|
pub extend CqlTime with Eq::{equal, not_equal}

///|
pub extend CqlTime with @debug.Debug::{to_repr}

///|
pub fn CqlTime::from_nanos(nanos : Int64) -> CqlTime raise ConversionError {
  if nanos < 0L || nanos >= 86400000000000L {
    raise ConversionError("time outside day")
  }
  { nanos, }
}

///|
pub fn CqlTime::nanos(self : CqlTime) -> Int64 {
  self.nanos
}

///|
pub fn CqlTime::to_value(self : CqlTime) -> Value {
  Time(self.nanos)
}

///|
pub fn CqlTime::to_string(self : CqlTime) -> String {
  let seconds = self.nanos / 1000000000L
  let clock = "\{pad((seconds / 3600L).to_string(), 2)}:\{pad((seconds / 60L % 60L).to_string(), 2)}:\{pad((seconds % 60L).to_string(), 2)}"
  let fraction = self.nanos % 1000000000L
  if fraction == 0L {
    clock
  } else {
    clock + "." + pad(fraction.to_string(), 9)
  }
}

///|
pub fn CqlTime::from_string(text : String) -> CqlTime raise ConversionError {
  let data = @utf8.encode(text)
  if data.length() < 8 ||
    data.length() > 18 ||
    data[2] != b':' ||
    data[5] != b':' {
    raise ConversionError("expected HH:MM:SS with optional nanoseconds")
  }
  let hour = decimal_digits(data, 0, 2)
  let minute = decimal_digits(data, 3, 5)
  let second = decimal_digits(data, 6, 8)
  if hour > 23L || minute > 59L || second > 59L {
    raise ConversionError("invalid time component")
  }
  let mut fraction = 0L
  if data.length() > 8 {
    if data[8] != b'.' {
      raise ConversionError("invalid fractional time")
    }
    fraction = decimal_digits(data, 9, data.length())
    for _ in data.length()..<18 {
      fraction *= 10L
    }
  }
  CqlTime::from_nanos(
    (hour * 3600L + minute * 60L + second) * 1000000000L + fraction,
  )
}

///|
pub struct CqlTimestamp {
  millis : Int64
} derive(Eq, @debug.Debug)

///|
pub extend CqlTimestamp with Eq::{equal, not_equal}

///|
pub extend CqlTimestamp with @debug.Debug::{to_repr}

///|
pub fn CqlTimestamp::from_millis(millis : Int64) -> CqlTimestamp {
  { millis, }
}

///|
pub fn CqlTimestamp::millis(self : CqlTimestamp) -> Int64 {
  self.millis
}

///|
pub fn CqlTimestamp::to_value(self : CqlTimestamp) -> Value {
  Timestamp(self.millis)
}

///|
pub fn CqlTimestamp::to_string(self : CqlTimestamp) -> String {
  let days = floor_div(self.millis, 86400000L)
  // 对余数单独归一化，避免最小 Int64 的 days * 86400000 中间值下溢。
  let remainder = self.millis % 86400000L
  let remainder = if remainder < 0L { remainder + 86400000L } else { remainder }
  let time = { nanos: remainder * 1000000L, }
  date_string(days) + "T" + time.to_string() + "Z"
}

///|
pub fn CqlTimestamp::from_string(
  text : String,
) -> CqlTimestamp raise ConversionError {
  if text.length() > 48 {
    raise ConversionError("timestamp too long")
  }
  for byte in @utf8.encode(text) {
    if byte.to_int() > 127 {
      raise ConversionError("timestamp must use ASCII digits and separators")
    }
  }
  let parts = text.split("T").to_array()
  if parts.length() != 2 {
    raise ConversionError("timestamp requires T separator and timezone")
  }
  let mut days = parse_date(parts[0].to_owned())
  let clock = parts[1].to_owned()
  let data = @utf8.encode(clock)
  if data.length() < 9 {
    raise ConversionError("timestamp requires timezone")
  }
  let mut offset = 0L
  let end_time = if data[data.length() - 1] == b'Z' {
    data.length() - 1
  } else {
    let start = data.length() - 6
    if start < 8 ||
      (data[start] != b'+' && data[start] != b'-') ||
      data[start + 3] != b':' {
      raise ConversionError("invalid timestamp offset")
    }
    let hours = decimal_digits(data, start + 1, start + 3)
    let minutes = decimal_digits(data, start + 4, data.length())
    if hours > 23L || minutes > 59L {
      raise ConversionError("timestamp offset out of range")
    }
    offset = (hours * 60L + minutes) * 60000L
    if data[start] == b'-' {
      offset = -offset
    }
    start
  }
  let time = CqlTime::from_string(clock[:end_time].to_owned())
  if time.nanos % 1000000L != 0L {
    raise ConversionError(
      "timestamp cannot represent sub-millisecond precision",
    )
  }
  let mut remainder = time.nanos / 1000000L - offset
  if remainder < 0L {
    days -= 1L
    remainder += 86400000L
  }
  if remainder >= 86400000L {
    days += 1L
    remainder -= 86400000L
  }
  if days < -106751991168L ||
    days > 106751991167L ||
    (days == -106751991168L && remainder < 60424192L) ||
    (days == 106751991167L && remainder > 25975807L) {
    raise ConversionError("timestamp outside Int64 range")
  }
  let millis = if days < 0L {
    (days + 1L) * 86400000L + (remainder - 86400000L)
  } else {
    days * 86400000L + remainder
  }
  { millis, }
}
