"""直接连接专用 Cassandra TLS 监听，分别报告单向／双向 TLS 与最小账户授权。"""
import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import secrets
import socket
import ssl
import subprocess
import time
import uuid

from cryptography import x509
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.serialization import pkcs12

from acceptance_common import ROOT, provenance, run, write_json
from native_runner import build_native
from tls_matrix import certificates, windows_certificate

PORT = 19064


class Fixture:
    def __init__(self, output=None):
        identity = uuid.uuid4().hex
        self.folder = (output or ROOT / '.artifacts' / ('native-tls-' + identity)).resolve()
        self.folder.mkdir(parents=True, exist_ok=False)
        self.certificates = ROOT / '.tools' / ('native-tls-' + identity)
        certificates(self.certificates)
        key = serialization.load_pem_private_key((self.certificates / 'server.key').read_bytes(), password=None)
        cert = x509.load_pem_x509_certificate((self.certificates / 'server.pem').read_bytes())
        ca = x509.load_pem_x509_certificate((self.certificates / 'ca.pem').read_bytes())
        encryption = serialization.BestAvailableEncryption(b'mooncql-fixture-only')
        (self.certificates / 'server.p12').write_bytes(pkcs12.serialize_key_and_certificates(b'server', key, cert, [ca], encryption))
        (self.certificates / 'trust.p12').write_bytes(pkcs12.serialize_java_truststore([pkcs12.PKCS12Certificate(ca, b'mooncql-ca')], encryption))
        self.binaries = {name: build_native('cmd/' + name) for name in ['tlscheck', 'least-privilege']}
        self.password = secrets.token_hex(24)

    def mode(self, mutual):
        write_json(self.certificates / 'mode.json', dict(mutual=mutual))

    def environment(self, *, business=False, compression='none', name='localhost', trust='ca', expected_failure=False):
        environment = {key: value for key, value in os.environ.items() if not key.startswith('CQL_')}
        environment.update(CQL_PORT=str(PORT), CQL_USERNAME='mooncql_business' if business else 'cassandra',
                           CQL_PASSWORD=self.password if business else 'cassandra', CQL_COMPRESSION=compression,
                           CQL_TLS_NAME=name, CQL_TLS_CA=str(self.certificates / (trust + '.pem')),
                           CQL_TLS_EXPECT_FAIL='1' if expected_failure else '0')
        return environment


class DockerController:
    def __init__(self, fixture):
        self.fixture = fixture
        self.project = 'mooncql-native-tls-' + uuid.uuid4().hex[:12]
        self.environment = dict(os.environ, CQL_NATIVE_TLS_FIXTURE_DIR=str(fixture.certificates))

    def compose(self, *arguments):
        return subprocess.run(['docker', 'compose', '--project-name', self.project, '-f', 'compose.native-tls.yaml', *arguments],
                              cwd=ROOT, env=self.environment, capture_output=True, encoding='utf-8', check=True, timeout=360).stdout

    def start(self, mutual):
        self.fixture.mode(mutual)
        self.compose('up', '-d', '--wait', '--wait-timeout', '240')

    def restart(self, mutual):
        self.compose('stop')
        self.start(mutual)

    def logs(self):
        return self.compose('logs', '--no-color', '--tail=200')

    def ensure_running(self):
        output = self.compose('ps', '--all', '--format', 'json').strip()
        records = json.loads(output) if output.startswith('[') else [json.loads(line) for line in output.splitlines() if line]
        if len(records) != 1 or records[0]['State'] != 'running':
            raise RuntimeError('Dedicated native TLS Cassandra stopped during startup')

    def stop(self):
        self.compose('down', '--volumes')


def ssl_context(fixture, identity=None):
    context = ssl.create_default_context(cafile=str(fixture.certificates / 'ca.pem'))
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    if identity:
        context.load_cert_chain(fixture.certificates / (identity + '.pem'), fixture.certificates / (identity + '.key'))
    return context


@contextlib.contextmanager
def admin(fixture, mutual):
    from cassandra.auth import PlainTextAuthProvider
    from cassandra.cluster import Cluster
    from cassandra.policies import WhiteListRoundRobinPolicy

    cluster = Cluster(['127.0.0.1'], port=PORT, protocol_version=5,
                      auth_provider=PlainTextAuthProvider('cassandra', 'cassandra'),
                      ssl_context=ssl_context(fixture, 'client' if mutual else None),
                      load_balancing_policy=WhiteListRoundRobinPolicy(['127.0.0.1']),
                      connect_timeout=2, control_connection_timeout=3)
    try:
        session = cluster.connect()
        assert session.execute('SELECT release_version FROM system.local').one().release_version == '5.0.5'
        yield session
    finally:
        cluster.shutdown()


def wait_ready(fixture, mutual, controller):
    deadline = time.monotonic() + 180
    while True:
        controller.ensure_running()
        try:
            with socket.create_connection(('127.0.0.1', PORT), timeout=2) as tcp:
                with ssl_context(fixture, 'client' if mutual else None).wrap_socket(tcp, server_hostname='localhost'):
                    pass
            with admin(fixture, mutual):
                return
        except ssl.SSLCertVerificationError:
            raise RuntimeError('Reference TLS certificate validation failed') from None
        except Exception:
            if time.monotonic() >= deadline:
                raise RuntimeError('Native TLS listener did not become ready') from None
            time.sleep(1)


def provision(fixture):
    with admin(fixture, False) as session:
        session.execute("CREATE KEYSPACE mooncql_permissions WITH replication={'class':'SimpleStrategy','replication_factor':1}")
        for table in ['business', 'private_data']:
            session.execute(f'CREATE TABLE mooncql_permissions.{table} (id int PRIMARY KEY,value text)')
        session.execute("CREATE ROLE mooncql_business WITH PASSWORD='" + fixture.password + "' AND LOGIN=true AND SUPERUSER=false")
        session.execute('GRANT SELECT ON TABLE mooncql_permissions.business TO mooncql_business')
        session.execute('GRANT MODIFY ON TABLE mooncql_permissions.business TO mooncql_business')
        permissions = list(session.execute('LIST ALL PERMISSIONS OF mooncql_business'))
        assert len(permissions) == 2 and {row.permission for row in permissions} == {'SELECT', 'MODIFY'}
        assert {row.resource for row in permissions} == {'<table mooncql_permissions.business>'}
        role = session.execute("SELECT is_superuser,can_login FROM system_auth.roles WHERE role='mooncql_business'").one()
        assert role.can_login and not role.is_superuser


@contextlib.contextmanager
def client_identity(fixture, environment, identity):
    environment = dict(environment)
    if not identity:
        yield environment
        return
    if os.name == 'nt':
        environment['CQL_TLS_CLIENT_THUMBPRINT'] = windows_certificate(fixture.certificates, identity)
    else:
        environment.update(CQL_TLS_CLIENT_CERT=str(fixture.certificates / (identity + '.pem')),
                           CQL_TLS_CLIENT_KEY=str(fixture.certificates / (identity + '.key')))
    try:
        yield environment
    finally:
        if os.name == 'nt':
            windows_certificate(fixture.certificates, identity, True)


def exercise(fixture, controller):
    report = dict(passed=False, listener='Cassandra native TLS', proxy_used=False, cases=[],
                  least_privilege=[], metadata_policy='Cassandra 5.0.5 authenticated-readable system resources', long_test_run=False)
    completed = False
    try:
        report['provenance'] = provenance(fixture.folder)
        report['ca_sha256'] = hashlib.sha256((fixture.certificates / 'ca.pem').read_bytes()).hexdigest()
        with socket.socket() as probe:
            assert probe.connect_ex(('127.0.0.1', PORT)) != 0, 'dedicated native TLS port is busy'
        controller.start(False)
        wait_ready(fixture, False, controller)
        provision(fixture)
        for mutual in [False, True]:
            if mutual:
                controller.restart(True)
                wait_ready(fixture, True, controller)
            prefix = 'mutual' if mutual else 'one-way'
            cases = [('dns', 'localhost', 'ca', 'client' if mutual else None, False),
                     ('ip', '127.0.0.1', 'ca', 'client' if mutual else None, False)]
            if mutual:
                cases += [('missing-client', 'localhost', 'ca', None, True),
                          ('untrusted-client', 'localhost', 'ca', 'foreign-client', True)]
            else:
                cases += [('wrong-name', 'wrong.invalid', 'ca', None, True),
                          ('untrusted-ca', 'localhost', 'foreign-ca', None, True)]
            for compression in ['none', 'lz4']:
                for name, hostname, trust, identity, failure in cases:
                    case = f'{prefix}-{compression}-{name}'
                    environment = fixture.environment(compression=compression, name=hostname, trust=trust, expected_failure=failure)
                    if not failure:
                        environment['CQL_TLS_LARGE'] = '1'
                    with client_identity(fixture, environment, identity) as environment:
                        output = run([fixture.binaries['tlscheck']], fixture.folder, case, env=environment, timeout=45)
                    assert ('PASS TLS rejected invalid peer or client credentials' if failure else 'PASS verified TLS query') in output
                    # 拒绝用例前后均核对真实 TLS／认证监听，避免把服务端停机误当成拒绝证书。
                    wait_ready(fixture, mutual, controller)
                    report['cases'].append(dict(case=case, passed=True, expected_failure=failure))
                    print('PASS native TLS', case, flush=True)
                environment = fixture.environment(business=True, compression=compression)
                with client_identity(fixture, environment, 'client' if mutual else None) as environment:
                    output = run([fixture.binaries['least-privilege']], fixture.folder, f'permissions-{prefix}-{compression}', env=environment)
                assert 'PASS minimum business SELECT/MODIFY' in output
                report['least_privilege'].append(dict(mutual=mutual, compression=compression, passed=True, explicit_grants=['SELECT', 'MODIFY']))
                print(f'PASS native TLS least privilege {prefix}/{compression}', flush=True)
        assert len(report['cases']) == 16 and len(report['least_privilege']) == 4
        completed = True
    finally:
        log_error = None
        try:
            (fixture.folder / 'server.log').write_text(controller.logs(), encoding='utf-8')
        except Exception as error:
            log_error = error
            report['log_error'] = type(error).__name__
        clean = False
        try:
            controller.stop()
            clean = True
        finally:
            report['passed'] = completed and clean and log_error is None
            report['server_stopped'] = clean
            write_json(fixture.folder / 'result.json', report)
        print('Native TLS artifacts:', fixture.folder, flush=True)
        if completed and log_error is not None:
            raise RuntimeError('Native TLS server logs could not be archived') from None


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--docker-compose', action='store_true', required=True)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    fixture = Fixture(args.output)
    exercise(fixture, DockerController(fixture))
