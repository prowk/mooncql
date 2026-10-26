"""普通源码变更不重复安装历史包，消费／依赖和未知范围不能漏掉完整验收。"""
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from package_scope import required


class PackageScopeTest(unittest.TestCase):
    def changed(self, paths, returncode=0):
        event = '{"before":"' + 'a' * 40 + '","after":"' + 'b' * 40 + '"}'
        with patch.dict('os.environ', {'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF': 'refs/heads/main', 'GITHUB_EVENT_PATH': 'event.json'}, clear=True), \
             patch('pathlib.Path.read_text', return_value=event), \
             patch('package_scope.subprocess.run', return_value=SimpleNamespace(returncode=returncode, stdout='\0'.join(paths).encode('utf-8'))):
            return required()

    def test_ordinary_function_change_only_needs_source_acceptance(self):
        self.assertFalse(self.changed(['client/session.mbt', 'client/session_test.mbt', 'docs/session.md']))

    def test_consumers_dependencies_and_release_contract_require_full_acceptance(self):
        for path in ['.github/workflows/ci.yml', 'examples/device-events/main.mbt', 'cmd/new/moon.pkg', 'moon.mod', 'fixtures/releases.json', 'docs/getting-started.md', 'scripts/requirements-metrics.txt']:
            with self.subTest(path=path):
                self.assertTrue(self.changed([path]))

    def test_unknown_history_manual_run_and_release_tag_require_full_acceptance(self):
        self.assertTrue(self.changed(['client/session.mbt'], returncode=128))
        for environment in [{'GITHUB_EVENT_NAME': 'workflow_dispatch'}, {'GITHUB_REF': 'refs/tags/v0.3.0'}, {}]:
            with patch.dict('os.environ', environment, clear=True):
                self.assertTrue(required())


if __name__ == '__main__':
    unittest.main()
