"""接口审计区分不透明内部状态与外部可构造字段，并对未知声明失败。"""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_api import declarations


class APIContractTest(unittest.TestCase):
    def test_opaque_private_fields_are_not_constructor_contracts(self):
        old = 'pub struct Session {\n  private_counter : Int\n}\n'
        new = 'pub struct Session {\n  different_private_state : String\n}\n'
        self.assertEqual(declarations(old), declarations(new))
        self.assertNotEqual(declarations(old.replace('pub struct', 'pub(all) struct')),
                            declarations(new.replace('pub struct', 'pub(all) struct')))

    def test_generic_functions_and_exhaustive_error_branches_remain_visible(self):
        source = ('pub async fn[T] Session::read(Self, T, timeout? : Int) -> T\n\n'
                  'pub(all) suberror Failure {\n  Closed\n  TimedOut\n}\n')
        parsed = declarations(source)
        self.assertEqual(set(parsed), {'fn Session::read', 'type Failure'})
        self.assertIn('TimedOut', parsed['type Failure'])
        self.assertNotEqual(parsed, declarations(source.replace('timeout? : Int', 'timeout? : Int64')))

    def test_unknown_or_incomplete_export_format_is_never_silently_ignored(self):
        for source in ['pub new_export Future\n', 'pub(all) struct Incomplete {\n  field : Int\n']:
            with self.subTest(source=source), self.assertRaises(ValueError):
                declarations(source)


if __name__ == '__main__':
    unittest.main()
