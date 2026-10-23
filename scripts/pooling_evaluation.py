"""固定总并发，随机交错比较单节点 1/2/4 连接；仅记录证据，不自动推荐生产池大小。"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import random
import statistics
import uuid

from acceptance_common import ROOT, provenance, run, write_json
from benchmark import build, generated_c_digest

SEED = 2026102301
CONNECTIONS = (1, 2, 4)
FIELDS = ('operations_per_second', 'p50_ns', 'p95_ns', 'p99_ns', 'cpu_percent', 'peak_memory_bytes', 'elapsed_ns')


def matrix(smoke=False):
    if smoke:
        return [dict(mode='read', size=64, entropy='repeat', compressed=True, count=128, concurrency=32, page_size=0)]
    result = []
    for compressed in (False, True):
        for concurrency in (32, 128):
            result.append(dict(mode='read', size=64, entropy='repeat', compressed=compressed, count=8192, concurrency=concurrency, page_size=0))
        result.extend([
            dict(mode='write', size=64, entropy='repeat', compressed=compressed, count=8192, concurrency=128, page_size=0),
            dict(mode='read', size=400000, entropy='random', compressed=compressed, count=128, concurrency=32, page_size=0),
            dict(mode='write', size=400000, entropy='random', compressed=compressed, count=64, concurrency=32, page_size=0),
            dict(mode='page', size=64, entropy='repeat', compressed=compressed, count=1024, concurrency=32, page_size=4),
        ])
    return result


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_sample(sample, case, connections):
    for key in ('mode', 'entropy'):
        require(sample.get(key) == case[key], f'benchmark changed {key}')
    for key in ('count', 'concurrency', 'size', 'page_size'):
        require(type(sample.get(key)) is int and sample[key] == case[key], f'benchmark changed {key}')
    require(type(sample.get('connections')) is int and sample['connections'] == connections, 'wrong physical connection count')
    require(sample.get('compressed') is case['compressed'], 'wrong compression')
    require(sample.get('server_version') == '5.0.5', 'unverified Cassandra version')
    if sample.get('uses_session_pool') is True:
        require(sample.get('physical_connections') == connections and sample.get('resources_drained') is True, 'Session pool did not open or drain the requested connections')
        require(type(sample.get('background_task_handles')) is int and sample['background_task_handles'] > 0, 'missing Session task accounting')
    for key in FIELDS:
        value = sample.get(key)
        require(type(value) in (int, float) and math.isfinite(value) and value >= 0, f'invalid measurement {key}')
    require(sample['elapsed_ns'] > 0 and sample['operations_per_second'] > 0 and sample['peak_memory_bytes'] > 0, 'missing timing or memory measurement')
    require(0 < sample['p50_ns'] <= sample['p95_ns'] <= sample['p99_ns'], 'invalid latency distribution')
    require(math.isclose(sample['operations_per_second'], sample['count'] * 1e9 / sample['elapsed_ns'], rel_tol=1e-6), 'throughput does not match count and elapsed time')
    if case['mode'] == 'page':
        require(type(sample.get('page_count')) is int and sample['page_count'] >= case['count'], 'missing page measurements')


def summarize(records, cases, trials):
    expected = {(case_id, trial, size) for case_id in range(len(cases)) for trial in range(trials) for size in CONNECTIONS}
    seen = set()
    for record in records:
        identity = (record.get('case_id'), record.get('trial'), record.get('connections'))
        require(identity in expected and identity not in seen, 'unexpected or duplicated trial')
        validate_sample(record, cases[identity[0]], identity[2])
        seen.add(identity)
    require(seen == expected, 'incomplete measurement matrix')
    summary = []
    for case_id, case in enumerate(cases):
        variants = {}
        for size in CONNECTIONS:
            samples = [record for record in records if record['case_id'] == case_id and record['connections'] == size]
            variants[str(size)] = {
                'median': {field: statistics.median(record[field] for record in samples) for field in FIELDS},
                'range': {field: [min(record[field] for record in samples), max(record[field] for record in samples)] for field in FIELDS},
            }
        baseline = variants['1']['median']
        for size in CONNECTIONS:
            current = variants[str(size)]
            current['throughput_ratio_to_one'] = current['median']['operations_per_second'] / baseline['operations_per_second']
            current['p99_ratio_to_one'] = current['median']['p99_ns'] / baseline['p99_ns']
            one = {record['trial']: record for record in records if record['case_id'] == case_id and record['connections'] == 1}
            selected = {record['trial']: record for record in records if record['case_id'] == case_id and record['connections'] == size}
            current['paired_throughput_ratios'] = [selected[trial]['operations_per_second'] / one[trial]['operations_per_second'] for trial in range(trials)]
            current['paired_p99_ratios'] = [selected[trial]['p99_ns'] / one[trial]['p99_ns'] for trial in range(trials)]
        summary.append({'case_id': case_id, **case, 'connections': variants})
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--smoke', action='store_true', help='只验证三种连接数的入口，不作为性能结论')
    parser.add_argument('--session', action='store_true', help='测量真实 Session 池，默认测量低层连接原型')
    parser.add_argument('--trials', type=int, default=3)
    parser.add_argument('--case-id', action='append', type=int, help='按完整矩阵的编号选择复测场景，可重复指定')
    parser.add_argument('--count-scale', type=int, default=1, help='统一放大各场景操作数，保持连接数之间一致')
    parser.add_argument('--server-description', default='unspecified; interpretation requires actual server resources')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    trials = 1 if args.smoke else args.trials
    require(1 <= trials <= 20 and (args.smoke or trials >= 3), 'full evaluation requires 3-20 trials')
    require(1 <= args.count_scale <= 16, 'count scale must be 1-16')
    cases = matrix(args.smoke)
    selected = sorted(set(args.case_id)) if args.case_id else list(range(len(cases)))
    require(all(0 <= case_id < len(cases) for case_id in selected), 'invalid selected case id')
    cases = [dict(cases[case_id], original_case_id=case_id, count=cases[case_id]['count'] * args.count_scale) for case_id in selected]
    folder = (args.output or ROOT / '.artifacts' / ('pooling-evaluation-' + uuid.uuid4().hex)).resolve()
    folder.mkdir(parents=True, exist_ok=False)
    (ROOT / '.artifacts/latest-pooling-dir.txt').write_text(str(folder), encoding='utf-8')
    report = {
        'passed': False, 'smoke': args.smoke, 'seed': SEED, 'trials': trials, 'cases': cases,
        'selected_case_ids': selected, 'count_scale': args.count_scale,
        'logical_cpus': os.cpu_count(),
        'server_description': args.server_description, 'uses_session_pool': args.session,
        'scope': 'same benchmark binary, same total concurrency, same synthetic data; setup/warmup excluded from latency and CPU, process lifetime peak memory; client measurements only',
    }
    try:
        report['provenance'] = provenance(folder)
        package = 'cmd/poolbench' if args.session else 'cmd/bench'
        binary = build(ROOT, package)
        report['generated_c_sha256'] = generated_c_digest(ROOT, package)
        report['script_sha256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        report['harness_sha256'] = hashlib.sha256((ROOT / package / 'main.mbt').read_bytes()).hexdigest()
        report['clock_sha256'] = hashlib.sha256((ROOT / package / 'clock.c').read_bytes()).hexdigest()
        randomizer = random.Random(SEED)
        tasks = [(case_id, trial) for case_id in range(len(cases)) for trial in range(trials)]
        randomizer.shuffle(tasks)
        records = []
        with (folder / 'records.jsonl').open('w', encoding='utf-8') as stream:
            for case_id, trial in tasks:
                case = cases[case_id]
                variants = list(CONNECTIONS)
                randomizer.shuffle(variants)
                for size in variants:
                    environment = dict(os.environ, BENCH_MODE=case['mode'], BENCH_SIZE=str(case['size']), BENCH_ENTROPY=case['entropy'],
                                       BENCH_COUNT=str(case['count']), BENCH_CONCURRENCY=str(case['concurrency']), BENCH_PAGE_SIZE=str(max(1, case['page_size'])),
                                       BENCH_CONNECTIONS=str(size), CQL_COMPRESSION='lz4' if case['compressed'] else 'none')
                    text = run([binary], folder, f'{case_id}-{trial}-{size}', env=environment, timeout=240)
                    record = json.loads(text.splitlines()[-1])
                    require(record.get('uses_session_pool', False) is args.session, 'wrong benchmark driver scope')
                    validate_sample(record, case, size)
                    record.update(case_id=case_id, trial=trial)
                    records.append(record)
                    stream.write(json.dumps(record, ensure_ascii=False) + '\n')
                    stream.flush()
                    print(json.dumps(record), flush=True)
        report['summary'] = summarize(records, cases, trials)
        report['sample_count'] = len(records)
        report['passed'] = True
    except Exception as error:
        report['failure'] = f'{type(error).__name__}: {error}'
        raise
    finally:
        report['finished_utc'] = datetime.now(timezone.utc).isoformat()
        write_json(folder / 'result.json', report)
    print(('PASS pooling smoke only: ' if args.smoke else 'PASS pooling measurement matrix; review raw trials before deciding: ') + str(folder / 'result.json'), flush=True)


if __name__ == '__main__':
    main()
