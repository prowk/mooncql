"""定位原生产物时兼容不同 Moon 工具链的可执行文件后缀。"""
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from benchmark import build


class BenchmarkBuildTest(unittest.TestCase):
    def test_native_artifact_suffix_is_detected_instead_of_inferred_from_os(self):
        for suffix in ('.exe', ''):
            with self.subTest(suffix=suffix), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                output = root / '_build/native/release/build/cmd/poolbench' / ('poolbench' + suffix)
                output.parent.mkdir(parents=True)
                output.write_bytes(b'fixture')
                with patch('benchmark.command'):
                    self.assertEqual(Path(build(root, 'cmd/poolbench')), output)


if __name__ == '__main__':
    unittest.main()
