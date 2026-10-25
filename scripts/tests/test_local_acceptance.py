"""验收入口必须保留跳过原因，并在超时时终止自己的子进程。"""
from pathlib import Path
import socket
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from acceptance_common import run
from local_acceptance import preflight


class LocalAcceptanceTest(unittest.TestCase):
    def test_occupied_port_and_memory_shortage_cannot_report_ready(self):
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            with patch('local_acceptance.PORTS', {'single': [listener.getsockname()[1]]}), \
                    patch('local_acceptance.available_memory', return_value=1024), \
                    patch('local_acceptance.shutil.which', return_value=None):
                result = preflight('single')
        self.assertFalse(result['ready'])
        self.assertTrue(any('occupied' in reason for reason in result['problems']))
        self.assertTrue(any('memory' in reason for reason in result['problems']))

    def test_timeout_preserves_output_and_reaps_owned_process(self):
        with tempfile.TemporaryDirectory() as target:
            folder = Path(target)
            with self.assertRaisesRegex(RuntimeError, 'timed out'):
                run([sys.executable, '-c', 'import time; print("started", flush=True); time.sleep(60)'],
                    folder, 'probe', timeout=1)
            self.assertIn('started', (folder / 'probe.stdout.log').read_text(encoding='utf-8'))
            self.assertTrue((folder / 'probe.stderr.log').exists())
