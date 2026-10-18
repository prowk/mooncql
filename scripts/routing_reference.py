"""用独立 Cassandra Python 驱动核验 routing key 与 Cassandra Murmur3 固定样例。"""

import argparse
import bisect
from dataclasses import dataclass
import json
from pathlib import Path
import random

ROOT = Path(__file__).resolve().parent.parent


def vectors():
    from cassandra.cqltypes import Int32Type, UTF8Type, BytesType
    from cassandra.metadata import Murmur3Token
    from cassandra.protocol import ColumnMetadata
    from cassandra.query import PreparedStatement
    from cassandra.metadata import SimpleStrategy, NetworkTopologyStrategy

    randomizer = random.Random(20261018)
    cases = []
    for length in [*range(1, 34), 63, 64, 65, 127, 128, 129, 1023]:
        key = bytes(randomizer.randrange(256) for _ in range(length))
        cases.append({"key": key.hex(), "token": Murmur3Token.from_key(key).value})
    for key in [b"\xff", b"\x80", b"\x80\x01", b"hello", "月".encode("utf-8")]:
        cases.append({"key": key.hex(), "token": Murmur3Token.from_key(key).value})
    metadata = [ColumnMetadata("ks", "t", "a", Int32Type), ColumnMetadata("ks", "t", "b", UTF8Type), ColumnMetadata("ks", "t", "c", BytesType)]
    routing_keys = []
    for indices in [[0], [1], [1, 0], [2, 1, 0]]:
        statement = PreparedStatement(metadata, b"id", indices, "query", "ks", 5, [], b"meta")
        key = statement.bind([7, "月", b"\x80\xff"]).routing_key
        routing_keys.append({"indices": indices, "key": key.hex(), "token": Murmur3Token.from_key(key).value})
    @dataclass(frozen=True)
    class Host:
        index: int
        datacenter: str
        rack: str

    nodes = [Host(0, "dc1", "r1"), Host(1, "dc1", "r1"), Host(2, "dc1", "r2"),
             Host(3, "dc2", "r1"), Host(4, "dc2", "r2"), Host(5, "dc2", "r3")]
    owners = {-80: nodes[0], -50: nodes[1], -20: nodes[3], 0: nodes[0], 20: nodes[2],
              40: nodes[4], 80: nodes[5], 90: nodes[3]}
    ring = sorted(Murmur3Token(token) for token in owners)
    token_owners = {Murmur3Token(token): host for token, host in owners.items()}
    replica_cases = []
    strategies = [*(('SimpleStrategy', {'replication_factor': str(factor)}) for factor in [1, 2, 4, 99]),
                  ('NetworkTopologyStrategy', {'dc1': '2', 'dc2': '1'}),
                  ('NetworkTopologyStrategy', {'dc1': '3', 'dc2': '2'}),
                  ('NetworkTopologyStrategy', {'dc1': '5', 'dc2': '0'})]
    for name, options in strategies:
        strategy = SimpleStrategy(options) if name == 'SimpleStrategy' else NetworkTopologyStrategy(options)
        replicas = strategy.make_token_replica_map(token_owners, ring)
        for token in [-100, -80, -79, -20, -19, 0, 1, 50, 90, 99, 100]:
            offset = bisect.bisect_left(ring, Murmur3Token(token)) % len(ring)
            replica_cases.append({'strategy': dict(options, **{'class': name}), 'token': token,
                                  'replicas': sorted(host.index for host in replicas[ring[offset]])})
    return {"reference": "cassandra-driver==3.30.0", "seed": 20261018,
            "empty_key_token": -(1 << 63), "cases": cases, "routing_keys": routing_keys,
            "ring_nodes": [{'index': host.index, 'dc': host.datacenter, 'rack': host.rack,
                            'tokens': [token for token, owner in owners.items() if owner == host]} for host in nodes],
            "replica_cases": replica_cases}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    expected = vectors()
    target = ROOT / "fixtures/routing.json"
    if args.write:
        target.write_text(json.dumps(expected, indent=2, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n")
    assert json.loads(target.read_text(encoding="utf-8")) == expected
    print("PASS independent Cassandra routing-key and Murmur3 vectors")


if __name__ == "__main__":
    main()
