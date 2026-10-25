///|
test "stable cursor container corpus round trips and seeded byte mutations stay bounded" {
  let corpus = [
    b"MCQLPG01\x00\x00\x00\x06secret\x00\xff\xff\xff\xff", b"MCQLPG01\x00\x00\x00\x06secret\x00\x00\x00\x00\x04next",
    b"MCQLPG01\x00\x00\x00\x06secret\x01\xff\xff\xff\xff",
  ]
  let random = [2026102501U]
  for golden in corpus {
    let cursor = @client.PagingCursor::from_bytes(golden)
    assert_eq(cursor.to_bytes(), golden)
    assert_true(!cursor.to_repr().to_string().contains("secret"))
    for end in 0..<golden.length() {
      assert_true(
        try {
          ignore(@client.PagingCursor::from_bytes(golden[:end].to_owned()))
          false
        } catch {
          @codec.CodecError(_) => true
        },
      )
    }
    for _ in 0..<512 {
      let changed = golden.to_array()
      let position = model_random(random, changed.length())
      changed[position] = (changed[position].to_int() ^
      (1 << model_random(random, 8))).to_byte()
      let input = Bytes::from_array(changed)
      let decoded = Some(@client.PagingCursor::from_bytes(input)) catch {
        @codec.CodecError(_) => None
      }
      if decoded is Some(decoded) {
        // 游标没有签名，修改绑定值或合法状态可成功；只能保证格式往返和上下文匹配。
        assert_eq(decoded.to_bytes(), input)
      }
    }
  }
}

///|
test "cursor extreme lengths extra tail and completion conflicts fail before oversized copies" {
  for
    bytes in [
      b"MCQLPG01\x7f\xff\xff\xff", b"MCQLPG01\x80\x00\x00\x00", b"MCQLPG01\x01\x00\x00\x01",
      b"MCQLPG01\x00\x00\x00\x01x\x00\x7f\xff\xff\xff", b"MCQLPG01\x00\x00\x00\x01x\x00\x80\x00\x00\x00",
      b"MCQLPG01\x00\x00\x00\x01x\x01\x00\x00\x00\x00", b"MCQLPG01\x00\x00\x00\x01x\x01\xff\xff\xff\xfftail",
    ] {
    assert_true(
      try {
        ignore(@client.PagingCursor::from_bytes(bytes))
        false
      } catch {
        @codec.CodecError(_) => true
      },
    )
  }
}
