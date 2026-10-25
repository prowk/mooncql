"""缩减器只接受仍复现同一性质失败的候选。"""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from replay_model import shrink


class ModelReplayTest(unittest.TestCase):
    def test_shrinking_preserves_failure_and_has_a_bounded_attempt_count(self):
        attempts = []
        def fails(config):
            attempts.append(config)
            return config['width'] >= 6 and config['cancels'] >= 2
        result = shrink(dict(width=12, cancels=4, fragment=31), fails)
        self.assertEqual(result, dict(width=6, cancels=2, fragment=1))
        self.assertLessEqual(len(attempts), 9)
