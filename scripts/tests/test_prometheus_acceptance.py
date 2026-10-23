"""独立 Prometheus 解析后的重复序列、无界标签和畸形直方图不能通过验收。"""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from prometheus_acceptance import validate_text


def histogram():
    bounds = ['0', '0.001', '0.005', '0.01', '0.025', '0.05', '0.1', '0.25', '0.5', '1', '5', '+Inf']
    counts = [0, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2]
    lines = ['# TYPE mooncql_probe_seconds histogram']
    lines += [f'mooncql_probe_seconds_bucket{{session="main",le="{bound}"}} {count}' for bound, count in zip(bounds, counts)]
    lines += ['mooncql_probe_seconds_count{session="main"} 2', 'mooncql_probe_seconds_sum{session="main"} 0.026']
    return '\n'.join(lines) + '\n'


class PrometheusAcceptanceTest(unittest.TestCase):
    def test_valid_cumulative_histogram_is_parsed_by_the_reference_library(self):
        samples, groups = validate_text(histogram())
        self.assertEqual(groups, 1)
        self.assertEqual(len(samples), 14)

    def test_nonfinite_values_duplicates_or_unapproved_labels_are_rejected(self):
        for invalid in [
            histogram() + 'mooncql_bad{session="main"} NaN\n',
            histogram() + 'mooncql_bad{session="main"} +Inf\n',
            histogram() + 'mooncql_bad{session="main",cql="secret"} 1\n',
            histogram() + 'mooncql_probe_seconds_sum{session="main"} 0.026\n',
        ]:
            with self.subTest(text=invalid[-80:]), self.assertRaises((AssertionError, ValueError)):
                validate_text(invalid)

    def test_incomplete_or_nonmonotonic_histograms_are_rejected(self):
        for invalid in [
            histogram().replace('le="0.001"} 1', 'le="0.001"} 3'),
            histogram().replace('le="+Inf"} 2', 'le="6"} 2'),
            histogram().replace('mooncql_probe_seconds_count{session="main"} 2', 'mooncql_probe_seconds_count{session="main"} 3'),
        ]:
            with self.subTest(text=invalid[-80:]), self.assertRaises((AssertionError, ValueError)):
                validate_text(invalid)


if __name__ == '__main__':
    unittest.main()
