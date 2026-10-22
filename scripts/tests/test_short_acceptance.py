"""防止验收脚本在缺页、缺字段断言或部分失败时仍然报告通过。"""
import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from short_acceptance import validate_integration


class ShortAcceptanceTest(unittest.TestCase):
    def setUp(self):
        self.report = {
            'rows': 10000, 'checksum': 49995000, 'simple_checksum': 49995000,
            'protocol': 5, 'server': '5.0.5', 'page_size': 113,
            'simple_pages': 89, 'page_sizes': [113] * 88 + [56],
            'terminal_states': [False] * 88 + [True], 'paging_ended': True,
            'prepared_pages': 79, 'large_payload_bytes': 400000, 'large_payload_two_way': True,
            'batch': ['logged', 'unlogged', 'counter'], 'ttl': True,
            'metadata_updated': True, 'field_checks': True,
        }

    def test_fixed_conditions_reproduce_claim(self):
        self.assertTrue(validate_integration(self.report)['matches_claim'])

    def test_short_server_pages_are_reported_without_overriding_correctness(self):
        self.report.update(simple_pages=90, page_sizes=[112] * 89 + [32],
                           terminal_states=[False] * 89 + [True])
        result = validate_integration(self.report)
        self.assertFalse(result['matches_claim'])
        self.assertEqual(result['actual_pages'], 90)

    def test_missing_rows_or_wrong_checksum_fail(self):
        for key, value in [('rows', 9999), ('checksum', 49995001), ('simple_checksum', 49995001),
                           ('page_sizes', [113] * 88 + [55])]:
            with self.subTest(key=key):
                report = copy.deepcopy(self.report)
                report[key] = value
                with self.assertRaises(AssertionError):
                    validate_integration(report)

    def test_paging_must_reach_one_terminal_state_at_end(self):
        for states in [[False] * 89, [True] + [False] * 87 + [True]]:
            self.report['terminal_states'] = states
            with self.assertRaises(AssertionError):
                validate_integration(self.report)

    def test_each_required_subcheck_is_mandatory(self):
        for key in ['field_checks', 'ttl', 'metadata_updated', 'large_payload_two_way', 'paging_ended']:
            with self.subTest(key=key):
                report = copy.deepcopy(self.report)
                report[key] = False
                with self.assertRaises(AssertionError):
                    validate_integration(report)
        self.report['batch'].remove('unlogged')
        with self.assertRaises(AssertionError):
            validate_integration(self.report)


if __name__ == '__main__':
    unittest.main()
