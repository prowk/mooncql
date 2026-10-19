"""配置专用性能实例，避免最大分页场景使用小堆和默认五秒读期限。"""
import os
from pathlib import Path
import re


def configure(path):
    text = path.read_text(encoding='utf-8')
    authenticator = os.environ.get('CQL_AUTHENTICATOR', 'PasswordAuthenticator')
    assert authenticator in ['AllowAllAuthenticator', 'PasswordAuthenticator']
    settings = {'authenticator': authenticator, 'native_transport_allow_older_protocols': 'false',
                'read_request_timeout': '30000ms', 'range_request_timeout': '30000ms',
                'write_request_timeout': '30000ms', 'request_timeout': '60000ms'}
    for key, value in settings.items():
        text, count = re.subn(r'^' + re.escape(key) + r':[^\n]*', f'{key}: {value}', text, flags=re.M)
        assert count == 1, key
    path.write_text(text, encoding='utf-8', newline='\n')


if __name__ == '__main__':
    configure(Path('/etc/cassandra/cassandra.yaml'))
