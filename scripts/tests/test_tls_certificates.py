"""测试证书应符合严格 X.509 校验，不能通过放宽客户端验证解决夹具缺陷。"""
from pathlib import Path
import sys
import tempfile
import unittest

from cryptography import x509

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tls_matrix import certificates


class TLSCertificatesTest(unittest.TestCase):
    def test_issued_certificates_include_matching_key_identifiers_and_ca_key_usage(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            certificates(folder)
            ca = x509.load_pem_x509_certificate((folder / 'ca.pem').read_bytes())
            ca_id = ca.extensions.get_extension_for_class(x509.SubjectKeyIdentifier).value.digest
            self.assertTrue(ca.extensions.get_extension_for_class(x509.KeyUsage).value.key_cert_sign)
            for name in ['server', 'client']:
                certificate = x509.load_pem_x509_certificate((folder / (name + '.pem')).read_bytes())
                authority = certificate.extensions.get_extension_for_class(x509.AuthorityKeyIdentifier).value.key_identifier
                self.assertEqual(authority, ca_id)
                self.assertFalse(certificate.extensions.get_extension_for_class(x509.KeyUsage).value.key_cert_sign)
                self.assertTrue(certificate.extensions.get_extension_for_class(x509.KeyUsage).value.digital_signature)


if __name__ == '__main__':
    unittest.main()
