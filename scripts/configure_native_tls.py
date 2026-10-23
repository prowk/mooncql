"""专用 Cassandra 原生 TLS 监听，保持 Native Protocol v5 与最小权限授权可核对。"""
import json
from pathlib import Path
import re

def configure(source, mutual, certificate_directory='/opt/mooncql/certs'):
    assert type(mutual) is bool
    settings = {
        'native_transport_allow_older_protocols': False,
        'authenticator': 'PasswordAuthenticator',
        'authorizer': 'CassandraAuthorizer',
        'permissions_validity': '0ms',
        'roles_validity': '0ms',
        'concurrent_reads': 4,
        'concurrent_writes': 4,
        'concurrent_counter_writes': 4,
        'concurrent_materialized_view_writes': 4,
        'native_transport_max_threads': 16,
        'memtable_flush_writers': 1,
        'concurrent_compactors': 1,
    }
    for name, value in settings.items():
        line = name + ': ' + json.dumps(value)
        if re.search('^' + name + ':', source, re.M):
            source = re.sub('^' + name + ':.*$', line, source, flags=re.M)
        else:
            source += '\n' + line + '\n'
    options = {
        'enabled': True, 'optional': False,
        'keystore': certificate_directory + '/server.p12',
        'keystore_password': 'mooncql-fixture-only',
        'truststore': certificate_directory + '/trust.p12',
        'truststore_password': 'mooncql-fixture-only',
        'store_type': 'PKCS12', 'require_client_auth': mutual,
    }
    block = 'client_encryption_options:\n' + ''.join('  ' + name + ': ' + json.dumps(value) + '\n' for name, value in options.items())
    source, count = re.subn(r'(?ms)^client_encryption_options:\n.*?(?=^\S|\Z)', lambda _: block + '\n', source)
    assert count == 1
    return source


if __name__ == '__main__':
    mode = json.loads(Path('/opt/mooncql/certs/mode.json').read_text(encoding='utf-8'))
    path = Path('/etc/cassandra/cassandra.yaml')
    path.write_text(configure(path.read_text(encoding='utf-8'), mode['mutual']), encoding='utf-8', newline='\n')
