"""固定种子与独立 Cassandra 驱动、python-lz4 双向核对，语义和字节分别检查。"""
import argparse
import calendar
import decimal
import io
import json
import os
from pathlib import Path
import random
import socket
import struct
import subprocess
import uuid

from cassandra import cqltypes as ct
from cassandra.util import Date, Time, Duration, SortedSet
import lz4.block
from native_runner import build_native
from differential_boundaries import corpus

ROOT = Path(__file__).resolve().parents[1]
SEED = 2026101819
SCALARS = {1: ct.AsciiType, 2: ct.LongType, 3: ct.BytesType, 4: ct.BooleanType,
           5: ct.CounterColumnType, 6: ct.DecimalType, 7: ct.DoubleType, 8: ct.FloatType,
           9: ct.Int32Type, 11: ct.TimestampType, 12: ct.UUIDType, 13: ct.UTF8Type,
           14: ct.IntegerType, 15: ct.TimeUUIDType, 16: ct.InetAddressType,
           17: ct.SimpleDateType, 18: ct.TimeType, 19: ct.ShortType, 20: ct.ByteType,
           21: ct.DurationType}


def i32(value):
    return struct.pack('>i', value)


def blob(value):
    return i32(-1) if value is None else i32(len(value)) + value


def string(value):
    data = value.encode('utf-8')
    return struct.pack('>H', len(data)) + data


def metadata(spec):
    kind, children = spec
    result = struct.pack('>H', kind)
    if kind == 48:
        result += string('ks') + string('generated') + struct.pack('>H', len(children))
        return result + b''.join(string(f'f{i}') + metadata(child) for i, child in enumerate(children))
    if kind == 49:
        result += struct.pack('>H', len(children))
    return result + b''.join(metadata(child) for child in children)


def driver_type(spec):
    kind, children = spec
    if kind in SCALARS:
        return SCALARS[kind]
    subtypes = tuple(driver_type(child) for child in children)
    if kind == 48:
        return ct.UserType.make_udt_class('ks', 'generated', tuple(f'f{i}' for i in range(len(children))), subtypes)
    return {32: ct.ListType, 33: ct.MapType, 34: ct.SetType, 49: ct.TupleType}[kind].apply_parameters(subtypes)


def make_spec(rng, depth=0):
    if depth >= 4 or rng.randrange(4) == 0:
        return rng.choice(list(SCALARS)), []
    kind = rng.choice([32, 33, 34, 48, 49])
    if kind == 32:
        return kind, [make_spec(rng, depth + 1)]
    if kind == 33:
        return kind, [(13, []), make_spec(rng, depth + 1)]
    if kind == 34:
        return kind, [(9, [])]
    return kind, [make_spec(rng, depth + 1) for _ in range(rng.randint(1, 3))]


def make_value(spec, rng):
    kind, children = spec
    if kind in [1, 13]: return ''.join(rng.choice('abcXYZ012' + ('中文月\x00' if kind == 13 else '')) for _ in range(rng.randrange(30)))
    if kind in [2, 5]: return rng.randint(-2**63, 2**63-1)
    if kind == 3: return rng.randbytes(rng.randrange(100))
    if kind == 4: return bool(rng.randrange(2))
    if kind == 6: return decimal.Decimal((rng.randrange(2), tuple(rng.randrange(10) for _ in range(rng.randint(1, 100))), rng.randint(-50, 50)))
    if kind in [7, 8]: return rng.randint(-100000, 100000) / 4
    if kind == 9: return rng.randint(-2**31, 2**31-1)
    if kind == 11: return rng.randint(0, 4000000000) * 1000
    if kind in [12, 15]: return uuid.UUID(int=rng.getrandbits(128))
    if kind == 14: return rng.getrandbits(rng.randint(1, 4096)) * rng.choice([-1, 1])
    if kind == 16: return socket.inet_ntop(socket.AF_INET6, rng.randbytes(16)) if rng.randrange(2) else socket.inet_ntop(socket.AF_INET, rng.randbytes(4))
    if kind == 17: return Date(rng.randint(-2**31, 2**31-1))
    if kind == 18: return Time(rng.randrange(86400000000000))
    if kind == 19: return rng.randint(-32768, 32767)
    if kind == 20: return rng.randint(-128, 127)
    if kind == 21:
        sign = rng.choice([-1, 1])
        return Duration(sign * rng.randint(0, 100000), sign * rng.randint(0, 100000), sign * rng.randint(0, 2**63-1))
    if kind == 32: return [make_value(children[0], rng) for _ in range(rng.randrange(5))]
    if kind == 34: return SortedSet(rng.randint(-1000, 1000) for _ in range(rng.randrange(5)))
    if kind == 33: return {f'key{i}': make_value(children[1], rng) for i in range(rng.randrange(5))}
    return tuple(None if rng.randrange(5) == 0 else make_value(child, rng) for child in children)


def view(spec, value):
    if value is None: return 'null'
    if value is ct.EMPTY: return 'empty'
    kind, children = spec
    if kind in [1, 13]: return 'text:' + value.encode('utf-8').hex()
    if kind in [9, 19, 20]: return 'int:' + str(value)
    if kind in [2, 5]: return 'long:' + str(value)
    if kind == 3: return 'blob:' + bytes(value).hex()
    if kind == 4: return 'bool:' + str(int(value))
    if kind == 6:
        parts = value.as_tuple()
        coefficient = int(''.join(map(str, parts.digits))) * (-1 if parts.sign else 1)
        return f'decimal:{-parts.exponent}:{coefficient}'
    if kind == 7: return 'double:' + str(struct.unpack('>q', struct.pack('>d', value))[0])
    if kind == 8: return 'float:' + str(struct.unpack('>i', struct.pack('>f', value))[0])
    if kind == 11: return 'timestamp:' + str(calendar.timegm(value.utctimetuple()) * 1000 + value.microsecond // 1000)
    if kind in [12, 15]: return 'uuid:' + value.bytes.hex()
    if kind == 14: return 'varint:' + str(value)
    if kind == 16: return 'inet:' + socket.inet_pton(socket.AF_INET6 if ':' in value else socket.AF_INET, value).hex()
    if kind == 17: return 'date:' + str(value.days_from_epoch)
    if kind == 18: return 'time:' + str(value.nanosecond_time)
    if kind == 21: return f'duration:{value.months}:{value.days}:{value.nanoseconds}'
    if kind in [32, 34]: return ('list' if kind == 32 else 'set') + '[' + ';'.join(view(children[0], item) for item in value) + ']'
    if kind == 33: return 'map[' + ';'.join(view(children[0], key) + '=' + view(children[1], item) for key, item in value.items()) + ']'
    if kind == 48: return 'udt[' + ';'.join(f'f{i}'.encode().hex() + '=' + view(child, item) for i, (child, item) in enumerate(zip(children, value))) + ']'
    return 'tuple[' + ';'.join(view(child, item) for child, item in zip(children, value)) + ']'


def read_blob(stream):
    header = stream.read(4)
    assert len(header) == 4
    size, = struct.unpack('>i', header)
    if size == -1: return None
    assert 0 <= size <= 67108864
    data = stream.read(size)
    assert len(data) == size
    return data


def mutate(data, rng):
    if not data: return rng.randbytes(rng.randrange(1, 9))
    kind = rng.randrange(4)
    if kind == 0: return data[:rng.randrange(len(data))]
    if kind == 1:
        index = rng.randrange(len(data))
        return data[:index] + bytes([data[index] ^ (1 << rng.randrange(8))]) + data[index + 1:]
    if kind == 2: return data + rng.randbytes(rng.randrange(1, 8))
    return rng.randbytes(rng.randrange(200))


def run(seed, count):
    rng = random.Random(seed)
    cases = []
    for _ in range(count):
        spec = make_spec(rng)
        typ = driver_type(spec)
        value = make_value(spec, rng)
        payload = typ.to_binary(value, 5)
        cases.append((0, spec, payload))
    # 保存已缩减的规范差异：布尔真值、非 NULL 空标量、UDT／tuple 省略末字段。
    cases += [(0, (4, []), b'\x02'), (0, (4, []), b'\xff'), (0, (9, []), b''),
              (0, (48, [(9, []), (13, [])]), blob(i32(7))),
              (0, (49, [(9, []), (13, [])]), blob(i32(7)))]
    ct.Int32Type.support_empty_values = True
    for typ in SCALARS.values():
        typ.support_empty_values = True
    boundary_cases, boundary_names = corpus(metadata, blob, i32)(driver_type)
    cases += boundary_cases
    for size in [0, 1, 4, 12, 15, 16, 255, 256, 65535, 65536, 131071, 131072, 400000]:
        for compressible in [False, True]:
            payload = (b'abcd' * ((size + 3) // 4))[:size] if compressible else rng.randbytes(size)
            # v5 单块解压上限 131071；400000 字节消息按协议分块核对。
            for offset in range(0, max(1, size), 131071):
                block = payload[offset:offset + 131071]
                cases.append((1, block, lz4.block.compress(block, store_size=False)))
    for _ in range(count):
        _, spec, payload = cases[rng.randrange(count)]
        type_bytes = metadata(spec)
        cases.append((2, mutate(type_bytes, rng) if rng.randrange(2) else type_bytes, mutate(payload, rng)))
        sample = rng.randbytes(rng.randrange(512)) if rng.randrange(2) else b'abc' * rng.randrange(100)
        compressed = lz4.block.compress(sample, store_size=False)
        cases.append((3, mutate(compressed, rng), rng.choice([len(sample), rng.randrange(4097), 2147483647, -1])))
    chunks = [b'MCQLDIF1', i32(len(cases))]
    for kind, left, right in cases:
        chunks.append(bytes([kind]))
        if kind == 0: chunks.extend([blob(metadata(left)), blob(right)])
        elif kind in [1, 2, 5]: chunks.extend([blob(left), blob(right)])
        elif kind == 4: chunks.append(bytes([left]))
        else: chunks.extend([blob(left), i32(right)])
    data = b''.join(chunks)
    assert len(data) <= 67108864
    folder = ROOT / '.artifacts' / f'differential-{seed}-{uuid.uuid4().hex}'
    folder.mkdir(parents=True)
    (folder / 'input.bin').write_bytes(data)
    environment = dict(os.environ, CQL_DIFFERENTIAL_DIR=str(folder))
    result = subprocess.run([build_native('cmd/differential')], cwd=ROOT, env=environment,
                            capture_output=True, encoding='utf-8', timeout=90,
                            creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
    (folder / 'stderr.log').write_text(result.stderr, encoding='utf-8')
    assert result.returncode == 0, (folder, result.stdout[-4000:], result.stderr[-4000:])
    stream = io.BytesIO((folder / 'output.bin').read_bytes())
    assert stream.read(12) == b'MCQLDIF1' + i32(len(cases))
    accepted = 0
    for index, (kind, left, right) in enumerate(cases):
        if kind == 0:
            typ = driver_type(left)
            expected = typ.from_binary(right, 5)
            actual_view = read_blob(stream).decode('utf-8')
            encoded = read_blob(stream)
            assert actual_view == view(left, expected), (index, left, actual_view, view(left, expected), folder)
            assert typ.from_binary(encoded, 5) == expected, (index, left, folder)
        elif kind == 1:
            assert lz4.block.decompress(read_blob(stream), uncompressed_size=len(left)) == left, index
        elif kind == 4:
            assert stream.read(4) == i32([-1, -2, 0][left]), index
        elif kind == 5:
            assert stream.read(1) == b'\x00', (index, left.hex(), folder)
        else:
            flag = stream.read(1)
            assert flag in [b'\x00', b'\x01']
            accepted += flag == b'\x01'
    assert stream.read() == b''
    report = {'seed': seed, 'nested_type_cases': sum(kind == 0 for kind, _, _ in cases), 'lz4_two_way_cases': sum(kind == 1 for kind, _, _ in cases),
              'mutated_type_and_lz4_cases': count * 2, 'accepted_mutations': accepted,
              'boundary_names': boundary_names, 'strict_rejected_cases': sum(kind == 5 for kind, _, _ in cases),
              'reference': 'cassandra-driver 3.30.0 and lz4 4.4.5'}
    (folder / 'result.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--seed', type=int, default=SEED)
    parser.add_argument('--count', type=int, default=800)
    args = parser.parse_args()
    assert 1 <= args.count <= 5000
    run(args.seed, args.count)
