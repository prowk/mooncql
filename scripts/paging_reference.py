"""使用独立驱动在服务重启后继续 MoonBit 导出的分页状态。"""
import os
from pathlib import Path
import struct

from cassandra.auth import PlainTextAuthProvider
from cassandra.cluster import Cluster, ExecutionProfile, EXEC_PROFILE_DEFAULT
from cassandra.policies import RoundRobinPolicy


def server_state(path):
    # 仅测试程序了解 MCQLPG01 容器；应用应通过 PagingCursor API 读写。
    data = Path(path).read_bytes()
    assert data[:8] == b'MCQLPG01' and len(data) <= 33554432
    size, = struct.unpack_from('>i', data, 8)
    assert 0 < size <= 16777216
    offset = 12 + size
    assert data[offset] == 0
    size, = struct.unpack_from('>i', data, offset + 1)
    assert size >= 0 and offset + 5 + size == len(data)
    return data[offset + 5:]


def verify(folder):
    username = os.environ.get('CQL_USERNAME')
    auth = PlainTextAuthProvider(username, os.environ.get('CQL_PASSWORD', '')) if username is not None else None
    cluster = Cluster([os.environ.get('CQL_HOST', '127.0.0.1')], port=int(os.environ.get('CQL_PORT', '9042')),
                      protocol_version=5, compression='lz4' if os.environ.get('CQL_COMPRESSION') == 'lz4' else False,
                      auth_provider=auth,
                      execution_profiles={EXEC_PROFILE_DEFAULT: ExecutionProfile(load_balancing_policy=RoundRobinPolicy())})
    try:
        session = cluster.connect('mooncql_recovery_a')
        statement = session.prepare('SELECT id FROM page_probe WHERE partition=?')
        statement.fetch_size = 17
        for name in ['simple', 'prepared']:
            rows = session.execute(statement, [7], paging_state=server_state(Path(folder) / f'paging-{name}.bin'))
            assert [row.id for row in rows] == list(range(17, 101)), name
        assert [row.id for row in session.execute(statement, [7])] == list(range(101))
        print('PASS independent driver resumes both MoonBit paging states after restart', flush=True)
    finally:
        cluster.shutdown()
