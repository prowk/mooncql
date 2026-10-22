"""保证安装引导不会接受错误校验和或提取归档中的任意文件。"""
import hashlib
import io
from pathlib import Path
import sys
import tarfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from precache_nushell import binary_from_archive, verify_archive


class BootstrapTest(unittest.TestCase):
    def test_checksum_requires_exact_file_and_digest(self):
        data = b'archive'
        digest = hashlib.sha256(data).hexdigest()
        verify_archive('nu.zip', data, f'{digest}  nu.zip\n')
        for manifest in [f'{digest}  another.zip\n', f'{"0" * 64}  nu.zip\n', f'{digest}  nu.zip\n{digest}  nu.zip\n']:
            with self.assertRaises(AssertionError):
                verify_archive('nu.zip', data, manifest)

    def test_windows_extracts_only_the_binary_as_bytes(self):
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, 'w') as archive:
            archive.writestr('package/nu.exe', b'binary')
            archive.writestr('../../unwanted.txt', b'ignored')
        self.assertEqual(binary_from_archive(stream.getvalue(), True), b'binary')

    def test_linux_rejects_symlink_as_binary(self):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w:gz') as archive:
            member = tarfile.TarInfo('package/nu')
            member.type = tarfile.SYMTYPE
            member.linkname = '/bin/false'
            archive.addfile(member)
        with self.assertRaises(AssertionError):
            binary_from_archive(stream.getvalue(), False)


if __name__ == '__main__':
    unittest.main()
