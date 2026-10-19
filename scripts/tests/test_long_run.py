"""混合负载验收的回归：Int64 字符串、实际数值进度及失败门槛。"""
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from long_run import ROOT, analyze, integer, trend


class LongRunAcceptanceTest(unittest.TestCase):
    def setUp(self):
        parent = ROOT / '.artifacts'
        parent.mkdir(exist_ok=True)
        temporary = tempfile.TemporaryDirectory(prefix='controller-regression-', dir=parent)
        self.folder = Path(temporary.name)
        assert self.folder.resolve().is_relative_to(parent.resolve())
        self.addCleanup(temporary.cleanup)
        operations = {name: '1' for name in ['read', 'write', 'page', 'lwt', 'batch', 'cache', 'schema']}
        self.result = {'load_elapsed_ms': 360000, 'background_joined': True,
                       'active': 0, 'waiting': 0, 'pending': 0, 'cache_peak': 16, 'cache_capacity': 16,
                       'operations': operations, 'final_metrics': {name: '0' for name in [
                           'in_flight', 'waiting', 'in_flight_bytes', 'waiting_bytes']}}
        self.result['final_metrics'].update(connections_established='12', connections_closed='12')
        self.samples = [{'elapsed_ms': index * 10000, 'successful': index * 100, 'failed': 0,
                         'memory_bytes': 16000000, 'private_bytes': 8000000,
                         'operations': dict(operations, read=str(9 + index), write=str(9 + index))}
                        for index in range(37)]

    def save(self):
        (self.folder / 'result.json').write_text(json.dumps(self.result), encoding='utf-8')
        (self.folder / 'samples.jsonl').write_text(
            ''.join(json.dumps(row) + '\n' for row in self.samples), encoding='utf-8')

    def check(self, faults=None):
        self.save()
        return analyze(self.folder, 360, True, [{'node': 0}] if faults is None else faults)

    def test_int64_values_do_not_pass_through_float(self):
        for value in [0, 9007199254740993, 9223372036854775807, -9223372036854775808]:
            self.assertEqual(integer(str(value)), value)
            self.assertEqual(integer(value), value)
        for value in [True, 1.0, '1.0', ' 1', 'NaN', '1e3']:
            with self.assertRaises(AssertionError):
                integer(value)

    def test_decimal_string_metrics_and_numerical_progress(self):
        report = self.check()
        self.assertFalse(report['qualifies_six_hour_run'])
        self.assertEqual(report['fault_cycles'], 1)

    def test_counter_regression_is_rejected(self):
        self.samples[29]['operations']['read'] = '8'
        with self.assertRaises(AssertionError):
            self.check()

    def test_no_actual_fault_is_rejected(self):
        with self.assertRaises(AssertionError):
            self.check(faults=[])

    def test_nonzero_inflight_bytes_are_rejected(self):
        self.result['final_metrics']['in_flight_bytes'] = '1'
        with self.assertRaises(AssertionError):
            self.check()

    def test_missing_schema_success_is_rejected(self):
        self.result['operations']['schema'] = '0'
        with self.assertRaises(AssertionError):
            self.check()

    def test_short_run_cannot_qualify_as_six_hours(self):
        self.save()
        with self.assertRaises(AssertionError):
            analyze(self.folder, 360, False, [{'node': 0}, {'node': 1}, {'node': 2}])

    def test_linear_memory_growth_is_detected(self):
        samples = [{'elapsed_ms': index * 300000, 'successful': str(9007199254740993 + index * 100000),
                    'failed': '0', 'memory_bytes': str(16000000 + index * 3145728)} for index in range(12)]
        self.assertTrue(trend(samples, 'memory_bytes', 0)['linear_growth_detected'])
        for row in samples:
            row['memory_bytes'] = '16000000'
        self.assertFalse(trend(samples, 'memory_bytes', 0)['linear_growth_detected'])


if __name__ == '__main__':
    unittest.main()
