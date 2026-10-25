"""同一 TCP 模拟负载在稳定版与候选之间至少三轮交错，不启动数据库。"""
import argparse
import json
import os
import random
import statistics
import uuid

from acceptance_common import ROOT, provenance, run, write_json
from benchmark import build, command
from load_benchmark import baseline
from observability_bench import source_digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-ref', default='v0.2.0')
    parser.add_argument('--trials', type=int, default=3)
    parser.add_argument('--rounds', type=int, default=16)
    parser.add_argument('--seed', type=int, default=2026102503)
    args = parser.parse_args()
    assert 3 <= args.trials <= 20 and 1 <= args.rounds <= 256
    folder = ROOT / '.artifacts' / ('reliability-benchmark-' + uuid.uuid4().hex)
    folder.mkdir(parents=True)
    report = {'passed': False, 'seed': args.seed, 'trials': args.trials, 'rounds': args.rounds, 'cases': [],
              'scope': 'loopback mock peer and client in same process, release native build; setup and mock encoding included in CPU/elapsed and peak RSS; raw per-operation latency excludes startup',
              'latency_scope': {'fairness': 'old large request completion under 32 new small requests',
                                'abandoned': 'cancelled 100000-row response drain, without result delivery',
                                'mixed': 'small queries mixed with 400KB blobs, 256 columns and eight-level collections',
                                'retry': 'explicit idempotent query, one OVERLOADED and fixed zero-delay retry; two RPCs per logical call'},
              'limitations': 'no allocator allocation count; RSS is not allocations; no claim of production throughput or leak freedom; does not compare different retry delay policies'}
    try:
        report['provenance'] = provenance(folder)
        previous = baseline(args.baseline_ref, 'reliabilitybench')
        current = dict(commit=command(['git', 'rev-parse', 'HEAD']), source_sha256=source_digest(ROOT), binary=build(ROOT, 'cmd/reliabilitybench'))
        report['sources'] = {name: {key: value for key, value in source.items() if key != 'binary'}
                             for name, source in [('baseline', previous), ('candidate', current)]}
        randomizer = random.Random(args.seed)
        for mode in ['fairness', 'abandoned', 'mixed', 'retry']:
            samples = []
            for trial in range(args.trials):
                variants = [('baseline', previous), ('candidate', current)]
                randomizer.shuffle(variants)
                for variant, source in variants:
                    name = f'{mode}-{trial}-{variant}'
                    output = run([source['binary']], folder, name,
                                 env=dict(os.environ, RELIABILITY_MODE=mode, RELIABILITY_ROUNDS=str(args.rounds)), timeout=120)
                    records = [json.loads(line) for line in output.splitlines()]
                    summary = records[-1]
                    raw = [record for record in records if record['type'] == 'sample']
                    assert summary['type'] == 'summary' and summary['mode'] == mode and summary['failures'] == 0
                    assert summary['count'] == len(raw) == args.rounds * (8 if mode == 'mixed' else 1)
                    assert {sample['id'] for sample in raw} == set(range(len(raw)))
                    assert all(sample['latency_ns'] > 0 for sample in raw)
                    samples.append(dict(variant=variant, trial=trial, raw_file=name + '.stdout.log', **summary))
                    print(name, 'p99_ns', summary['p99_ns'], 'cpu_ns', summary['cpu_ns'], flush=True)
            report['cases'].append({'mode': mode, 'trials': samples, 'median': {
                variant: {field: statistics.median(sample[field] for sample in samples if sample['variant'] == variant)
                          for field in ['elapsed_ns', 'cpu_ns', 'peak_memory_bytes', 'p99_ns']}
                for variant in ['baseline', 'candidate']}})
        report['passed'] = True
    finally:
        write_json(folder / 'result.json', report)
        print('Reliability benchmark report:', folder / 'result.json', flush=True)


if __name__ == '__main__':
    main()
