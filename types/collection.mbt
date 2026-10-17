///|
pub fn encode_value(value : Value) -> Bytes raise @codec.CodecError {
  encode_value_at(value, 0)
}

///|
fn write_nested(
  w : @codec.Writer,
  value : Value,
  depth : Int,
) -> Unit raise @codec.CodecError {
  match value {
    Null => w.bytes(None)
    Unset => raise @codec.CodecError("nested unset value")
    _ => w.bytes(Some(encode_value_at(value, depth)))
  }
}

///|
fn encode_value_at(value : Value, depth : Int) -> Bytes raise @codec.CodecError {
  if depth >= 32 {
    raise @codec.CodecError("value nesting exceeds limit")
  }
  let w = @codec.Writer::new()
  match value {
    ListValue(items) | SetValue(items) => {
      if items.length() > 1000000 {
        raise @codec.CodecError("too many collection elements")
      }
      w.i32(items.length())
      for item in items {
        if item == Null || item == Unset {
          raise @codec.CodecError("null or unset collection element")
        }
        write_nested(w, item, depth + 1)
      }
    }
    MapValue(items) => {
      if items.length() > 1000000 {
        raise @codec.CodecError("too many map entries")
      }
      w.i32(items.length())
      for (key, value) in items {
        if key == Null || value == Null || key == Unset || value == Unset {
          raise @codec.CodecError("null or unset map entry")
        }
        write_nested(w, key, depth + 1)
        write_nested(w, value, depth + 1)
      }
    }
    TupleValue(items) =>
      for item in items {
        write_nested(w, item, depth + 1)
      }
    UdtValue(items) =>
      for (_, item) in items {
        write_nested(w, item, depth + 1)
      }
    _ => return encode_scalar(value)
  }
  w.to_bytes()
}

///|
fn read_non_null(
  r : @codec.Reader,
  typ : CqlType,
  depth : Int,
) -> Value raise @codec.CodecError {
  let bytes = r.bytes()
  if bytes is None {
    raise @codec.CodecError("null collection element")
  }
  decode_value_at(typ, bytes, depth)
}

///|
fn checked_count(
  r : @codec.Reader,
  minimum_width : Int,
) -> Int raise @codec.CodecError {
  let count = r.i32()
  if count < 0 || count > 1000000 || count > r.remaining() / minimum_width {
    raise @codec.CodecError("invalid collection count")
  }
  count
}

///|
fn decode_composite(
  typ : CqlType,
  r : @codec.Reader,
  depth : Int,
) -> Value raise @codec.CodecError {
  match typ {
    List(element) | Set(element) => {
      let count = checked_count(r, 4)
      let items = []
      for i = 0; i < count; i = i + 1 {
        items.push(read_non_null(r, element, depth + 1))
      }
      if typ is List(_) {
        ListValue(items)
      } else {
        SetValue(items)
      }
    }
    Map(key_type, value_type) => {
      let count = checked_count(r, 8)
      let items = []
      for i = 0; i < count; i = i + 1 {
        let key = read_non_null(r, key_type, depth + 1)
        let value = read_non_null(r, value_type, depth + 1)
        items.push((key, value))
      }
      MapValue(items)
    }
    Tuple(fields) => {
      let items = []
      for field in fields {
        items.push(decode_value_at(field, r.bytes(), depth + 1))
      }
      TupleValue(items)
    }
    Udt(_, _, fields) => {
      let items = []
      for (name, field) in fields {
        items.push((name, decode_value_at(field, r.bytes(), depth + 1)))
      }
      UdtValue(items)
    }
    _ => raise @codec.CodecError("expected composite type")
  }
}

///|
pub fn snapshot(values : Array[Value]) -> Array[Value] raise @codec.CodecError {
  values.map(value => snapshot_at(value, 0))
}

///|
fn snapshot_at(value : Value, depth : Int) -> Value raise @codec.CodecError {
  if depth >= 32 {
    raise @codec.CodecError("value nesting exceeds limit")
  }
  match value {
    ListValue(items) =>
      ListValue(items.map(item => snapshot_at(item, depth + 1)))
    SetValue(items) => SetValue(items.map(item => snapshot_at(item, depth + 1)))
    MapValue(items) =>
      MapValue(
        items.map(pair => {
          (snapshot_at(pair.0, depth + 1), snapshot_at(pair.1, depth + 1))
        }),
      )
    TupleValue(items) =>
      TupleValue(items.map(item => snapshot_at(item, depth + 1)))
    UdtValue(items) =>
      UdtValue(items.map(pair => (pair.0, snapshot_at(pair.1, depth + 1))))
    _ => value
  }
}
