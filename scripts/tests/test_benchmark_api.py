"""接口适配只换旧版本名称，不改变负载或配置值。"""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from benchmark_api import for_baseline


class BenchmarkAPIAdapterTest(unittest.TestCase):
    def test_old_interface_keeps_exact_limits_and_load_expression(self):
        source = ('let config = @client.ConnectionBuilder::new(max_in_flight=128, max_waiting=64)\n'
                  '@client.with_connection_builder(config~, connection => run_load(connection, 400000, 32))\n')
        expected = source.replace('ConnectionBuilder', 'Config').replace('with_connection_builder', 'with_connection')
        self.assertEqual(for_baseline(source, 'pub(all) struct Config {'), expected)

    def test_current_interface_is_unchanged(self):
        source = '@client.with_session_builder(config=@client.SessionBuilder::new(), body)'
        self.assertEqual(for_baseline(source, 'pub(all) struct ConnectionBuilder {'), source)


if __name__ == '__main__':
    unittest.main()
