"""用固定独立 Prometheus 客户端解析器核对真实驱动导出和资源排空。"""
import argparse
import importlib.metadata
import math
import os
from pathlib import Path
import uuid

from acceptance_common import ROOT, provenance, run, write_json
from native_runner import build_native


def validate_text(text):
    from prometheus_client.parser import text_string_to_metric_families

    assert text.endswith('\n')
    samples = {}
    histograms = []
    allowed = {'session', 'node', 'scope', 'opcode', 'outcome', 'operation', 'reason', 'phase', 'event', 'le'}
    for family in text_string_to_metric_families(text):
        assert family.name.startswith('mooncql_')
        for sample in family.samples:
            identity = (sample.name, tuple(sorted(sample.labels.items())))
            assert identity not in samples, 'duplicated series'
            assert set(sample.labels) <= allowed and sample.labels.get('session') == 'main'
            assert math.isfinite(sample.value) and sample.value >= 0
            samples[identity] = sample.value
        if family.type == 'histogram':
            histograms.append(family)
    assert samples and histograms
    groups_checked = 0
    for family in histograms:
        groups = {}
        for sample in family.samples:
            labels = tuple(sorted((key, value) for key, value in sample.labels.items() if key != 'le'))
            group = groups.setdefault(labels, dict(buckets={}, count=None, sum=None))
            if sample.name.endswith('_bucket'):
                boundary = float(sample.labels['le'])
                assert boundary not in group['buckets']
                group['buckets'][boundary] = sample.value
            elif sample.name.endswith('_count'):
                group['count'] = sample.value
            elif sample.name.endswith('_sum'):
                group['sum'] = sample.value
        for group in groups.values():
            buckets = sorted(group['buckets'].items())
            assert len(buckets) == 12 and buckets[-1][0] == math.inf
            assert all(left[1] <= right[1] for left, right in zip(buckets, buckets[1:]))
            assert group['count'] == buckets[-1][1] and group['sum'] is not None
            groups_checked += 1
    return samples, groups_checked


def exercise(output):
    output.mkdir(parents=True, exist_ok=False)
    report = dict(passed=False)
    try:
        report['provenance'] = provenance(output)
        report['parser_version'] = importlib.metadata.version('prometheus-client')
        assert report['parser_version'] == '0.21.1'
        binary = build_native('cmd/prometheus')
        environment = dict(os.environ)
        environment.pop('CQL_METRICS_FILE', None)
        text = run([binary], output, 'exporter', env=environment) + '\n'
        (output / 'metrics.prom').write_text(text, encoding='utf-8')
        samples, groups = validate_text(text)

        def total(name, **labels):
            return sum(value for (actual, keys), value in samples.items() if actual == name and all(dict(keys).get(key) == expected for key, expected in labels.items()))

        assert total('mooncql_logical_started_total') == 4
        assert total('mooncql_logical_total', outcome='success') == 4
        assert total('mooncql_logical_total', operation='prepare', outcome='success') == 1
        assert total('mooncql_logical_total', operation='execute', outcome='success') == 3
        assert total('mooncql_rpc_total', scope='data') == 4
        assert total('mooncql_rpc_possible_sent_total', scope='data') == 4
        assert total('mooncql_rpc_total', scope='data', opcode='prepare') == 1
        assert total('mooncql_rpc_total', scope='data', opcode='execute') == 3
        assert total('mooncql_rpc_total', scope='heartbeat', opcode='options', outcome='success') >= 1
        assert total('mooncql_retry_attempts_total') == 0
        for suffix in ['active_operations', 'pending', 'abandoned', 'background_tasks', 'in_flight', 'in_flight_bytes', 'waiting', 'waiting_bytes']:
            name = 'mooncql_session_' + suffix
            assert any(actual == name for actual, _ in samples), 'missing resource gauge'
            assert total(name) == 0, name
        report.update(passed=True, samples=len(samples), histogram_groups=groups, logical_calls=4,
                      data_rpc=4, successful_heartbeats=total('mooncql_rpc_total', scope='heartbeat', opcode='options', outcome='success'),
                      resources_zero=True)
        print('PASS Prometheus reference parser, logical/RPC/heartbeat counts, histograms and drained resources', flush=True)
    finally:
        write_json(output / 'result.json', report)
        print('Prometheus artifacts:', output, flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    exercise((args.output or ROOT / '.artifacts' / ('prometheus-' + uuid.uuid4().hex)).resolve())
