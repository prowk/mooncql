///|
test "Session pool backoff schema discovery and routing combinations reject named boundaries before I/O" {
  let base = SessionBuilder::new()
  for
    (name, config) in [
      ("connections_per_node", { ..base, connections_per_node: 0, }),
      ("connections_per_node", { ..base, connections_per_node: 9, }),
      ("backoff_initial_ms", { ..base, backoff_initial_ms: 0, }),
      (
        "backoff_max_ms",
        { ..base, backoff_initial_ms: 100, backoff_max_ms: 99, },
      ),
      ("stable_reset_ms", { ..base, stable_reset_ms: -1, }),
      ("jitter", { ..base, jitter: 0.0 / 0.0, }),
      (
        "schema_agreement.timeout_ms",
        { ..base, schema_agreement: SchemaAgreementConfig::new(timeout_ms=0), },
      ),
      (
        "schema_agreement.poll_interval_ms",
        {
          ..base,
          schema_agreement: SchemaAgreementConfig::new(poll_interval_ms=60001),
        },
      ),
      (
        "schema_agreement.max_nodes",
        { ..base, schema_agreement: SchemaAgreementConfig::new(max_nodes=0), },
      ),
      (
        "discovery.refresh_interval_ms",
        {
          ..base,
          discovery: Some(DiscoveryConfig::new(refresh_interval_ms=0)),
        },
      ),
      (
        "discovery.debounce_ms",
        { ..base, discovery: Some(DiscoveryConfig::new(debounce_ms=60001)), },
      ),
      (
        "discovery.max_nodes",
        { ..base, discovery: Some(DiscoveryConfig::new(max_nodes=65537)), },
      ),
      (
        "discovery.max_tokens_per_node",
        {
          ..base,
          discovery: Some(DiscoveryConfig::new(max_tokens_per_node=0)),
        },
      ),
      (
        "discovery.max_keyspaces",
        { ..base, discovery: Some(DiscoveryConfig::new(max_keyspaces=-1)), },
      ),
    ] {
    assert_true(
      try {
        config.validate()
        false
      } catch {
        Configuration(message) =>
          message.contains(name) && message.contains("..")
        _ => false
      },
    )
  }
  assert_true(
    try {
      { ..base, routing: Some(RoutingConfig::new("dc")), }.validate()
      false
    } catch {
      Configuration(message) =>
        message.contains("routing") && message.contains("discovery")
      _ => false
    },
  )
  assert_true(
    try {
      {
        ..base,
        routing: Some(RoutingConfig::new("")),
        discovery: Some(DiscoveryConfig::new()),
      }.validate()
      false
    } catch {
      Configuration(message) => message.contains("local_dc")
      _ => false
    },
  )
  SessionBuilder::new(
    backoff_initial_ms=2147483647,
    backoff_max_ms=2147483647,
    stable_reset_ms=2147483647,
    jitter=1.0,
    connections_per_node=8,
    discovery=DiscoveryConfig::new(
      refresh_interval_ms=2147483647,
      debounce_ms=60000,
      max_nodes=65536,
      max_tokens_per_node=65536,
      max_keyspaces=65536,
    ),
    schema_agreement=SchemaAgreementConfig::new(
      timeout_ms=2147483647,
      poll_interval_ms=60000,
      max_nodes=65536,
    ),
    limits=SessionLimits::new(
      max_in_flight=1048576,
      max_in_flight_bytes=2147483647,
      max_waiting=1048576,
      max_waiting_bytes=2147483647,
    ),
  ).validate()
}

///|
test "Deadline and retry extreme values validate without allocating their declared budgets" {
  for bad in [-2147483648, -1, 0] {
    assert_true(
      try {
        ignore(Deadline::after(bad))
        false
      } catch {
        Configuration(message) =>
          message.contains("deadline_ms") && message.contains("1..")
        _ => false
      },
    )
  }
  let deadline = Deadline::after(2147483647)
  assert_true(
    deadline.remaining_ms() > 0 && deadline.remaining_ms() <= 2147483647,
  )
  for
    policy in [
      RetryPolicy::new(max_attempts=0),
      RetryPolicy::new(max_attempts=65),
      RetryPolicy::new(delay_ms=-1),
    ] {
    assert_true(
      try {
        policy.validate()
        false
      } catch {
        Configuration(message) =>
          message.contains("retry.") && message.contains("..")
        _ => false
      },
    )
  }
  RetryPolicy::new(max_attempts=64, delay_ms=2147483647).validate()
  for name in ["page_size", "timeout_ms", "traversal_timeout_ms"] {
    assert_true(
      try {
        ignore(
          ExecutionProfile::new(
            page_size?=if name == "page_size" { Some(0) } else { None },
            timeout_ms?=if name == "timeout_ms" { Some(-1) } else { None },
            traversal_timeout_ms?=if name == "traversal_timeout_ms" {
              Some(0)
            } else {
              None
            },
          ),
        )
        false
      } catch {
        Configuration(message) =>
          message.contains(name) && message.contains("1..")
        _ => false
      },
    )
  }
}
