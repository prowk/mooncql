"""拒绝遗漏失败请求、重复样本和倒置时间线。"""
import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from load_benchmark import validate


class LoadBenchmarkTest(unittest.TestCase):
    def setUp(self):
        self.records = [dict(type='operation', id=0, planned_ns=0, enqueued_ns=0, dispatched_ns=10, completed_ns=20, outcome='timeout'),
                        dict(type='rpc', request_id=1, queued_at_ms=1, sending_at_ms=None, completed_at_ms=2),
                        dict(type='summary', count=1, successes=0, failures=0, timeouts=1, rejections=0, elapsed_ns=20)]

    def test_timeout_is_a_recorded_outcome_not_a_missing_sample(self):
        self.assertEqual(validate(self.records, 1)['timeouts'], 1)
        with self.assertRaises(AssertionError):
            validate(self.records[1:], 1)

    def test_duplicate_samples_and_inverted_timelines_fail(self):
        for change in ['duplicate', 'time', 'outcome', 'rpc']:
            records = copy.deepcopy(self.records)
            if change == 'duplicate':
                records.insert(0, records[0].copy())
            elif change == 'time':
                records[0]['dispatched_ns'] = 21
            elif change == 'outcome':
                records[-1]['timeouts'] = 0
            else:
                records[1]['sending_at_ms'] = 3
            with self.subTest(change=change), self.assertRaises(AssertionError):
                validate(records, 1)
