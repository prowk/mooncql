///|
fn value_view(value : @types.Value) -> String raise {
  match value {
    Null => "null"
    Unset => "unset"
    Empty => "empty"
    Text(value) => "text:" + @hex.encode(@utf8.encode(value))
    Integer(value) | SmallInteger(value) | TinyInteger(value) =>
      "int:" + value.to_string()
    BigInteger(value) => "long:" + value.to_string()
    Timestamp(value) => "timestamp:" + value.to_string()
    Date(value) => "date:" + value.to_string()
    Time(value) => "time:" + value.to_string()
    Boolean(value) => if value { "bool:1" } else { "bool:0" }
    Real(value) => "double:" + value.reinterpret_as_int64().to_string()
    Single(value) => "float:" + value.reinterpret_as_int().to_string()
    Bytes(value) => "blob:" + @hex.encode(value)
    Inet(value) => "inet:" + @hex.encode(value)
    Uuid(value) => "uuid:" + @hex.encode(value)
    VarInt(value) =>
      "varint:" + @types.CqlVarInt::from_bytes(value).to_decimal_string()
    Decimal(scale, value) =>
      "decimal:\{scale}:" +
      @types.CqlVarInt::from_bytes(value).to_decimal_string()
    Duration(months, days, nanos) => "duration:\{months}:\{days}:\{nanos}"
    ListValue(values) | SetValue(values) | TupleValue(values) => {
      let kind = match value {
        ListValue(_) => "list"
        SetValue(_) => "set"
        _ => "tuple"
      }
      let parts = []
      for item in values {
        parts.push(value_view(item))
      }
      kind + "[" + parts.join(";") + "]"
    }
    MapValue(values) => {
      let parts = []
      for pair in values {
        parts.push(value_view(pair.0) + "=" + value_view(pair.1))
      }
      "map[" + parts.join(";") + "]"
    }
    UdtValue(values) => {
      let parts = []
      for pair in values {
        parts.push(@hex.encode(@utf8.encode(pair.0)) + "=" + value_view(pair.1))
      }
      "udt[" + parts.join(";") + "]"
    }
  }
}

///|
async fn main {
  guard @env.get_env_var("CQL_DIFFERENTIAL_DIR") is Some(directory) else {
    fail("missing differential fixture directory")
  }
  let input = @fs.read_file("\{directory}/input.bin").binary()
  if input.length() > 67108864 {
    fail("differential corpus exceeds limit")
  }
  let reader = @codec.Reader::new(input)
  assert_eq(reader.take(8), b"MCQLDIF1")
  let count = reader.i32()
  if count < 0 || count > 20000 {
    fail("invalid differential case count")
  }
  let output = @codec.Writer::new()
  output.raw(b"MCQLDIF1")
  output.i32(count)
  for index in 0..<count {
    let kind = reader.u8()
    let outcome = try {
      match kind {
        0 => {
          guard reader.bytes() is Some(metadata) else { fail("missing type") }
          let type_reader = @codec.Reader::new(metadata)
          let typ = @types.read_type(type_reader)
          type_reader.finish()
          let value = @types.decode_value(typ, reader.bytes())
          output.long_string(value_view(value))
          @types.write_value(output, value)
        }
        1 => {
          guard reader.bytes() is Some(payload) else {
            fail("missing LZ4 payload")
          }
          guard reader.bytes() is Some(compressed) else {
            fail("missing reference LZ4 block")
          }
          assert_eq(
            @framing.lz4_decompress(compressed, payload.length()),
            payload,
          )
          output.bytes(Some(@framing.lz4_compress(payload)))
        }
        2 => {
          guard reader.bytes() is Some(metadata) else {
            fail("missing malformed type")
          }
          let payload = reader.bytes()
          let accepted = try {
            let type_reader = @codec.Reader::new(metadata)
            let typ = @types.read_type(type_reader)
            type_reader.finish()
            ignore(@types.decode_value(typ, payload))
            true
          } catch {
            _ => false
          }
          output.u8(if accepted { 1 } else { 0 })
        }
        3 => {
          guard reader.bytes() is Some(compressed) else {
            fail("missing malformed LZ4 block")
          }
          let size = reader.i32()
          let accepted = try {
            ignore(@framing.lz4_decompress(compressed, size))
            true
          } catch {
            _ => false
          }
          output.u8(if accepted { 1 } else { 0 })
        }
        _ => fail("unknown differential case kind")
      }
      Ok(())
    } catch {
      error => Err(error)
    }
    match outcome {
      Ok(_) => ()
      Err(error) => {
        println("failed differential case \{index} kind \{kind}")
        raise error
      }
    }
  }
  reader.finish()
  @fs.write_file("\{directory}/output.bin", output.to_bytes())
}
