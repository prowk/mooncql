///|
pub struct DecodeBudget {
  priv mut remaining : Int
}

///|
pub fn DecodeBudget::new(
  max_nodes? : Int = 1000000,
) -> DecodeBudget raise @codec.CodecError {
  if max_nodes < 1 || max_nodes > 1000000 {
    raise @codec.CodecError("decoded value node budget must be 1..1000000")
  }
  { remaining: max_nodes, }
}

///|
pub fn DecodeBudget::remaining_nodes(self : DecodeBudget) -> Int {
  self.remaining
}

///|
fn DecodeBudget::require(
  self : DecodeBudget,
  count : Int,
) -> Unit raise @codec.CodecError {
  if count < 0 || count > self.remaining {
    raise @codec.CodecError("decoded value node limit exceeded")
  }
}

///|
fn DecodeBudget::take(self : DecodeBudget) -> Unit raise @codec.CodecError {
  self.require(1)
  self.remaining -= 1
}
