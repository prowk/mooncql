"""使用成熟 Python 驱动核对 MoonBit 写入，再由 MoonBit 读取 Python 数据。"""

import datetime
import decimal
import os
import subprocess
import uuid

from cassandra.auth import PlainTextAuthProvider
from cassandra.cluster import Cluster, ExecutionProfile, EXEC_PROFILE_DEFAULT, NoHostAvailable
from cassandra.policies import RoundRobinPolicy
from cassandra.query import SimpleStatement
from cassandra.util import Date, Time, Duration


def main():
    username = os.environ.get('CQL_USERNAME')
    password = os.environ.get('CQL_PASSWORD')
    auth = PlainTextAuthProvider(username, password) if username is not None else None
    cluster = Cluster(
        [os.environ.get('CQL_HOST', '127.0.0.1')],
        port=int(os.environ.get('CQL_PORT', '9042')),
        protocol_version=5,
        compression="lz4" if os.environ.get("CQL_COMPRESSION") == "lz4" else False,
        auth_provider=auth,
        execution_profiles={EXEC_PROFILE_DEFAULT: ExecutionProfile(load_balancing_policy=RoundRobinPolicy())},
    )
    try:
        session = cluster.connect()
        assert cluster.protocol_version == 5
        if os.environ.get('CQL_ASSERT_V5_ONLY') == '1':
            legacy = Cluster(
                [os.environ.get('CQL_HOST', '127.0.0.1')],
                port=int(os.environ.get('CQL_PORT', '9042')),
                protocol_version=4, compression=False, auth_provider=auth,
                execution_profiles={EXEC_PROFILE_DEFAULT: ExecutionProfile(load_balancing_policy=RoundRobinPolicy())},
            )
            try:
                try:
                    legacy.connect()
                except NoHostAvailable as error:
                    assert any('version' in str(reason).lower() for reason in error.errors.values()), error
                else:
                    raise AssertionError('Server accepted an older native protocol')
            finally:
                legacy.shutdown()
            print('Server rejects older protocols; reference driver uses v5', flush=True)
        expected = int(os.environ.get('CQL_ROWS', '10000'))
        rows = session.execute(SimpleStatement(
            'SELECT id,large_value,message,recorded_at,tags,attrs FROM mooncql_test.events WHERE device=42',
            fetch_size=137,
        ))
        count = 0
        for row in rows:
            assert row.id == count, (row.id, count)
            assert row.large_value == 9007199254740993 + count
            assert row.message == f'事件 {count}'
            assert row.recorded_at == datetime.datetime(2023, 11, 14, 22, 13, 20) + datetime.timedelta(milliseconds=count)
            assert row.tags == ['moon', '中文']
            assert row.attrs == {'index': count}
            count += 1
        assert count == expected, (count, expected)
        print(f'Python verified all {count} MoonBit rows', flush=True)
        session.execute('CREATE TYPE IF NOT EXISTS mooncql_test.address (street text, zip int)')
        session.execute('''CREATE TABLE IF NOT EXISTS mooncql_test.interop (
            id int PRIMARY KEY, message text, big bigint, payload blob, flag boolean,
            real_value double, single_value float, uid uuid, time_uid timeuuid, ip inet,
            day date, clock time, small smallint, tiny tinyint, amount decimal, huge varint,
            pair frozen<tuple<text,int>>, address frozen<address>, tags set<text>)''')
        insert = session.prepare('''INSERT INTO mooncql_test.interop
            (id,message,big,payload,flag,real_value,single_value,uid,time_uid,ip,day,clock,small,tiny,amount,huge,pair,address,tags)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)''')
        session.execute(insert, (
            1, 'Python 中文', 9007199254740993, b'\x00\xff', True, -1.25, 1.5,
            uuid.UUID('00112233-4455-6677-8899-aabbccddeeff'),
            uuid.UUID('f47ac10b-58cc-11cf-a447-001122334455'), '127.0.0.1',
            Date('1970-01-02'), Time(123456789), -32768, -128, decimal.Decimal('123.45'),
            2 ** 100 + 3, ('tuple 中文', 42), ('Main 中文', 12345), {'moon', '中文'},
        ))
        session.execute('CREATE TABLE IF NOT EXISTS mooncql_test.interop_v5 (id int PRIMARY KEY, d duration, payload blob)')
        v5 = session.prepare('INSERT INTO mooncql_test.interop_v5 (id,d,payload) VALUES (?,?,?)')
        payload = bytes(i % 251 for i in range(400000))
        session.execute(v5, (1, Duration(-64, -128, -8192), payload))
        moonbit = session.execute('SELECT d,payload FROM mooncql_test.v5_values WHERE id=1').one()
        assert moonbit.d == Duration(64, 128, 8192)
        assert moonbit.payload == payload
        subprocess.run(['moon', 'run', 'cmd/interop'], check=True)
        v5_row = session.execute('SELECT d,payload FROM mooncql_test.interop_v5 WHERE id=2').one()
        assert v5_row.d == Duration(2147483647, 2147483647, 9223372036854775807)
        assert v5_row.payload == payload
        row = session.execute('SELECT message FROM mooncql_test.interop WHERE id=1').one()
        assert row.message == 'MoonBit verified Python', row.message
        print('PASS independent Python ↔ MoonBit interoperability', flush=True)
    finally:
        cluster.shutdown()


if __name__ == '__main__':
    main()
