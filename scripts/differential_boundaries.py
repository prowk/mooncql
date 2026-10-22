"""固定的独立边界语料；名称与失败种子一起保留，避免仅依赖随机命中。"""
import decimal
import struct


def corpus(metadata, blob, i32):
    cases = []
    names = []

    def add(name, spec, value, encode):
        cases.append((0, spec, encode(spec, value)))
        names.append(name)

    def populate(driver_type):
        encode = lambda spec, value: driver_type(spec).to_binary(value, 5)
        for kind in [1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21]:
            cases.extend([(0, (kind, []), None), (0, (kind, []), b'')])
            names.extend([f'null-{kind}', f'empty-{kind}'])
        for value in [-2**63, -1, 0, 1, 2**63 - 1]:
            add(f'int64-{value}', (2, []), value, encode)
        for sign in [-1, 1]:
            huge = sign * (10**1000 + 123456789)
            add(f'varint-1001-digits-{sign}', (14, []), huge, encode)
            for scale in [-10000, 10000]:
                value = decimal.Decimal((int(sign < 0), tuple(map(int, str(abs(huge)))), -scale))
                add(f'decimal-1001-digits-{sign}-scale-{scale}', (6, []), value, encode)
        from cassandra.util import Duration
        for value in [Duration(0, 0, 0), Duration(2**31-1, 2**31-1, 2**63-1),
                      Duration(-2**31, -2**31, -2**63), Duration(0, -1, -1)]:
            add(f'duration-{value}', (21, []), value, encode)
        nested = (33, [(13, []), (32, [(49, [(9, []), (48, [(13, []), (32, [(49, [(2, []), (13, [])])])])])])])
        add('map-list-tuple-udt-list-tuple-null', nested,
            {'设备': [(7, ('地址', [(-2**63, None), (2**63-1, '')]))]}, encode)
        for spec, value, name in [((32, [(9, [])]), [], 'empty-list'),
                                  ((33, [(13, []), (9, [])]), {}, 'empty-map'),
                                  ((49, [(13, []), (9, [])]), (None, 7), 'tuple-null-field'),
                                  ((48, [(13, []), (9, [])]), ('', None), 'udt-empty-null')]:
            add(name, spec, value, encode)
        # 根绑定值的 NULL、UNSET 与空值由协议长度区分，不能视为三个相同的空字节。
        for tag, name in [(0, 'binding-null'), (1, 'binding-unset'), (2, 'binding-empty')]:
            cases.append((4, tag, None))
            names.append(name)
        invalid = [
            ('negative-collection-length', metadata((32, [(9, [])])), i32(-1)),
            ('huge-collection-length', metadata((32, [(9, [])])), i32(2147483647)),
            ('truncated-scalar', metadata((2, [])), b'\x00'),
            ('truncated-tuple-field', metadata((49, [(9, [])])), i32(4) + b'\x01'),
            ('unset-result-field', metadata((49, [(9, [])])), i32(-2)),
            ('mixed-duration-sign', metadata((21, [])), b'\x02\x01\x02'),
            ('overdeep-type-seed-2026102201', b'\x00\x20' * 33 + b'\x00\x09', i32(0)),
        ]
        for name, typ, payload in invalid:
            cases.append((5, typ, payload))
            names.append(name)
        return cases, names

    return populate
