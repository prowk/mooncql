"""原生 TLS 配置应切换证书要求，保持独立监听并使用 Cassandra 5 的时长单位。"""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from configure_native_tls import configure


class NativeTLSConfigurationTest(unittest.TestCase):
    def test_tls_is_required_on_the_native_port_and_mutual_restart_replaces_one_block(self):
        original = ('native_transport_port: 9042\nclient_encryption_options:\n  enabled: false\n'
                    '  require_client_auth: false\nserver_encryption_options:\n  internode_encryption: none\n')
        one_way = configure(original, False)
        mutual = configure(one_way, True)
        self.assertEqual(mutual.count('client_encryption_options:'), 1)
        self.assertIn('  enabled: true\n  optional: false', mutual)
        self.assertIn('  require_client_auth: false', one_way)
        self.assertIn('  require_client_auth: true', mutual)
        self.assertIn('native_transport_port: 9042', mutual)
        self.assertIn('server_encryption_options:\n  internode_encryption: none', mutual)
        self.assertIn('permissions_validity: "0ms"', mutual)
        self.assertIn('roles_validity: "0ms"', mutual)
        self.assertIn('authorizer: "CassandraAuthorizer"', mutual)

    def test_certificate_paths_remain_literal_when_replacing_yaml(self):
        source = 'client_encryption_options:\n  enabled: false\n'
        configured = configure(source, True, 'C:\\fixture\\native')
        self.assertIn('"C:\\\\fixture\\\\native/server.p12"', configured)


if __name__ == '__main__':
    unittest.main()
