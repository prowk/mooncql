"""连接池结论不能由不完整、重复或失真的基准样本生成。"""
import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pooling_evaluation import CONNECTIONS, matrix, summarize, validate_sample


class PoolingEvaluationTest(unittest.TestCase):
    def setUp(self):
        self.case = matrix(True)[0]
        self.sample = {**self.case, 'connections': 1, 'server_version': '5.0.5', 'elapsed_ns': 1000000000,
                       'operations_per_second': 128, 'peak_memory_bytes': 1000000, 'cpu_percent': 20,
                       'p50_ns': 100, 'p95_ns': 200, 'p99_ns': 300}

    def test_connection_and_total_concurrency_must_match_the_requested_case(self):
        for key, value in [('connections', 2), ('connections', True), ('count', 129), ('concurrency', 128), ('compressed', False)]:
            sample = dict(self.sample, **{key: value})
            with self.assertRaises(ValueError):
                validate_sample(sample, self.case, 1)

    def test_nonfinite_measurements_invalid_tail_and_missing_memory_are_rejected(self):
        for key, value in [('cpu_percent', float('nan')), ('p99_ns', float('inf')), ('p99_ns', 50), ('elapsed_ns', 0), ('peak_memory_bytes', 0), ('operations_per_second', 999)]:
            with self.assertRaises(ValueError):
                validate_sample(dict(self.sample, **{key: value}), self.case, 1)

    def test_incomplete_or_duplicated_matrix_cannot_be_reported_as_complete(self):
        records = [dict(self.sample, connections=size, case_id=0, trial=trial) for size in CONNECTIONS for trial in range(3)]
        self.assertEqual(len(summarize(records, [self.case], 3)), 1)
        for invalid in [records[:-1], records + [copy.deepcopy(records[0])]]:
            with self.assertRaises(ValueError):
                summarize(invalid, [self.case], 3)

    def test_page_workloads_require_actual_page_measurements(self):
        case = next(case for case in matrix() if case['mode'] == 'page')
        sample = {**self.sample, **case, 'operations_per_second': case['count']}
        with self.assertRaises(ValueError):
            validate_sample(sample, case, 1)
        validate_sample(dict(sample, page_count=case['count']), case, 1)

    def test_session_scope_requires_actual_pool_and_resource_drain_evidence(self):
        sample = dict(self.sample, uses_session_pool=True, physical_connections=1, resources_drained=True, background_task_handles=3)
        validate_sample(sample, self.case, 1)
        for key, value in [('physical_connections', 2), ('resources_drained', False), ('background_task_handles', 0)]:
            with self.assertRaises(ValueError):
                validate_sample(dict(sample, **{key: value}), self.case, 1)


if __name__ == '__main__':
    unittest.main()
