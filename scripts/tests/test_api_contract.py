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

    def test_builtin_integer_aliases_preserve_nested_api_types(self):
        old = ('pub fn read(Array[(Int, UInt)], limit? : Int) -> Result[UInt, Int64]\n\n'
               'pub(all) struct Record {\n  value : (Int, Array[UInt])\n}\n\n'
               'pub(all) enum Value {\n  Integer(Int)\n  Unsigned(UInt)\n}\n')
        new = ('pub fn read(Array[(Int32, UInt32)], limit? : Int32) -> Result[UInt32, Int64]\n\n'
               'pub(all) struct Record {\n  value : (Int32, Array[UInt32])\n}\n\n'
               'pub(all) enum Value {\n  Integer(Int32)\n  Unsigned(UInt32)\n}\n')
        self.assertEqual(declarations(old), declarations(new))
        self.assertNotEqual(declarations(old), declarations(new.replace('Int64', 'Int32')))

    def test_integer_aliases_do_not_hide_constructor_or_field_renames(self):
        for old, new in [
            ('pub(all) enum Value {\n  Int\n}\n', 'pub(all) enum Value {\n  Int32\n}\n'),
            ('pub(all) enum Value {\n  UInt(Int)\n}\n', 'pub(all) enum Value {\n  UInt32(Int32)\n}\n'),
            ('pub(all) struct Value {\n  Int : Int\n}\n', 'pub(all) struct Value {\n  Int32 : Int32\n}\n'),
            ('pub fn read(Int? : Int) -> Int\n', 'pub fn read(Int32? : Int32) -> Int32\n'),
            ('pub fn read(UInt~ : UInt) -> UInt\n', 'pub fn read(UInt32~ : UInt32) -> UInt32\n'),
        ]:
            with self.subTest(old=old):
                self.assertNotEqual(declarations(old), declarations(new))

    def test_integer_aliases_do_not_hide_qualified_type_changes(self):
        old = 'pub fn read(@custom.Int) -> @custom.UInt\n'
        new = 'pub fn read(@custom.Int32) -> @custom.UInt32\n'
        self.assertNotEqual(declarations(old), declarations(new))


if __name__ == '__main__':
    unittest.main()
