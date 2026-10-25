"""固定到达率或固定并发的配对基准；保存全部成功、拒绝和超时样本。"""
import argparse
import io
import json
import os
from pathlib import Path
import random
import re
import shutil
import statistics
import subprocess
import sys
import time
import uuid
import zipfile

from acceptance_common import ROOT, provenance, run, write_json
from benchmark import build, command
from benchmark_api import for_baseline
from observability_bench import source_digest

LEGACY_TELEMETRY = '''///|
fn make_metrics(enabled : Bool, recording : Array[Bool], samples : Array[String]) -> @client.Metrics? {
  if !enabled { return None }
  Some(@client.Metrics::new(listener=event => {
    if recording[0] && event is RequestFinished(request) {
      samples.push("{\\"type\\":\\"legacy_rpc\\",\\"queue_ms\\":\\{request.queue_ms},\\"execution_ms\\":\\{request.execution_ms}}")
    }
  }))
}
'''


def baseline(ref, benchmark_package='loadbench'):
    assert benchmark_package in ('loadbench', 'reliabilitybench')
    commit = command(['git', 'rev-parse', '--verify', ref + '^{commit}'])
    assert re.fullmatch('[a-f0-9]{40}', commit)
    target = ROOT / '.tools' / (benchmark_package + '-baseline-' + commit[:12])
    if not target.exists():
        archive = subprocess.run(['git', 'archive', '--format=zip', commit], cwd=ROOT, check=True, capture_output=True).stdout
        target.mkdir(parents=True)
        with zipfile.ZipFile(io.BytesIO(archive)) as data:
            for entry in data.infolist():
                path = target / entry.filename
                assert path.resolve().is_relative_to(target.resolve())
                if entry.is_dir():
                    path.mkdir(parents=True, exist_ok=True)
                else:
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(data.read(entry))
        (target / '.source-commit').write_text(commit, encoding='utf-8')
    assert (target / '.source-commit').read_text(encoding='utf-8') == commit
    api = (target / 'client/pkg.generated.mbti').read_text(encoding='utf-8')
    package = target / 'cmd' / benchmark_package
    package.mkdir(parents=True, exist_ok=True)
    for path in (ROOT / 'cmd' / benchmark_package).iterdir():
        if path.is_file():
            if path.suffix == '.mbt':
                source = LEGACY_TELEMETRY if path.name == 'telemetry.mbt' and 'RequestTimeline' not in api else path.read_text(encoding='utf-8')
                if path.name == 'memory.mbt' and 'ReceiveMemorySnapshot' not in api:
                    source = '///|\nfn receive_note(_connection : @client.Connection) -> Unit {}\n'
                (package / path.name).write_text(for_baseline(source, api), encoding='utf-8')
            else:
                shutil.copyfile(path, package / path.name)
    command(['moon', 'update'], target)
    return {'commit': commit, 'source_sha256': source_digest(target), 'binary': build(target, 'cmd/' + benchmark_package),
            'rpc_timeline_available': 'RequestTimeline' in api}


def validate(records, count):
    summary = records[-1]
    assert summary['type'] == 'summary'
    operations = [sample for sample in records if sample['type'] == 'operation']
    assert len(operations) == count and {sample['id'] for sample in operations} == set(range(count))
    outcomes = {key: 0 for key in ('success', 'failed', 'timeout', 'rejected')}
    for sample in operations:
        assert 0 <= sample['planned_ns'] == sample['enqueued_ns'] <= sample['dispatched_ns'] <= sample['completed_ns']
        outcomes[sample['outcome']] += 1
    assert outcomes == dict(success=summary['successes'], failed=summary['failures'], timeout=summary['timeouts'], rejected=summary['rejections'])
    timelines = [sample for sample in records if sample['type'] == 'rpc']
    assert len({sample['request_id'] for sample in timelines}) == len(timelines)
    for sample in timelines:
        assert sample['queued_at_ms'] <= sample['completed_at_ms']
        if sample['sending_at_ms'] is not None:
            assert sample['queued_at_ms'] <= sample['sending_at_ms'] <= sample['completed_at_ms']
    assert summary['count'] == count and summary['elapsed_ns'] > 0
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-ref', default='v0.2.0')
    parser.add_argument('--trials', type=int, default=3)
    parser.add_argument('--count', type=int, default=256)
    parser.add_argument('--concurrency', type=int, default=32)
    parser.add_argument('--rate', type=int, default=1000)
    parser.add_argument('--seed', type=int, default=2026102502)
    parser.add_argument('--smoke', action='store_true')
    args = parser.parse_args()
    assert 3 <= args.trials <= 20 and 1 <= args.count <= 200000 and 1 <= args.concurrency <= 128 and 1 <= args.rate <= 1000000
    folder = ROOT / '.artifacts' / ('load-benchmark-' + uuid.uuid4().hex)
    folder.mkdir(parents=True)
    report = {'passed': False, 'seed': args.seed, 'trials': args.trials, 'raw_files': [], 'summary': [],
              'clock_scope': 'logical samples use monotonic ns relative to origin; RPC uses monotonic integer ms; sending means first socket write attempt, not server arrival',
              'queue_scope': 'open-loop arrivals enter a bounded implicit queue at planned time; dispatch delay includes scheduler and concurrency backlog; no silent arrival drops',
              'measurement_scope': 'all outcomes included in latency; process CPU excludes setup; peak RSS includes setup; raw formatting and correctness checks included',
              'baseline_telemetry': 'stable Metrics lacks absolute RPC timestamps; keep legacy queue/execution durations, do not invent sending timestamps',
              'limitations': 'single local node, one physical connection, short trials; not production sizing or long-run evidence'}
    runner_cpu = time.process_time_ns()
    try:
        report['provenance'] = provenance(folder)
        previous = baseline(args.baseline_ref)
        current = {'commit': command(['git', 'rev-parse', 'HEAD']), 'source_sha256': source_digest(ROOT),
                   'binary': build(ROOT, 'cmd/loadbench'), 'rpc_timeline_available': True}
        report['sources'] = {name: {key: value for key, value in source.items() if key != 'binary'}
                             for name, source in [('baseline', previous), ('candidate', current)]}
        cases = [dict(distribution=distribution, rate=rate, size=size, observe=observe)
                 for distribution in ['hot', 'uniform'] for rate in [0, args.rate]
                 for size in [64, 400000] for observe in ['off', 'on']]
        if args.smoke:
            cases = [dict(distribution='hot', rate=0, size=64, observe='on'),
                     dict(distribution='uniform', rate=args.rate, size=64, observe='on'),
                     dict(distribution='hot', rate=args.rate, size=400000, observe='on'),
                     dict(distribution='uniform', rate=0, size=400000, observe='on')]
        report['cases'] = cases
        randomizer = random.Random(args.seed)
        for case_id, case in enumerate(cases):
            samples = []
            for trial in range(args.trials):
                variants = [('baseline', previous), ('candidate', current)]
                randomizer.shuffle(variants)
                for variant, source in variants:
                    name = f'{case_id}-{trial}-{variant}'
                    env = dict(os.environ, LOAD_COUNT=str(args.count), LOAD_CONCURRENCY=str(args.concurrency),
                               LOAD_DISTRIBUTION=case['distribution'], LOAD_SIZE=str(case['size']),
                               LOAD_RATE=str(case['rate']), LOAD_OBSERVE=case['observe'])
                    output = run([source['binary']], folder, name, env=env, timeout=240)
                    records = [json.loads(line) for line in output.splitlines()]
                    summary = validate(records, args.count)
                    samples.append(dict(variant=variant, trial=trial, **summary))
                    report['raw_files'].append(name + '.stdout.log')
                    # 正确性失败不能被正常的负载统计掩盖；拒绝和超时仍有原始样本。
                    if summary['failures']:
                        raise RuntimeError('benchmark returned failed operations: ' + name)
                    print(name, 'success', summary['successes'], 'timeout', summary['timeouts'], 'rejected', summary['rejections'], flush=True)
            report['summary'].append({'case_id': case_id, **case, 'trials': samples,
                'median': {variant: {field: statistics.median(sample[field] for sample in samples if sample['variant'] == variant)
                                    for field in ('elapsed_ns', 'cpu_ns', 'peak_memory_bytes', 'p50_ns', 'p95_ns', 'p99_ns', 'failures', 'timeouts', 'rejections', 'sampling_overhead_ns')}
                           for variant in ('baseline', 'candidate')}})
        report['passed'] = True
    finally:
        report['runner_cpu_ns'] = time.process_time_ns() - runner_cpu
        write_json(folder / 'result.json', report)
        print('Load benchmark report:', folder / 'result.json', flush=True)


if __name__ == '__main__':
    main()
