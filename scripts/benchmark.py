"""在同一环境交错测量基线和当前版本；每次请求均验证结果。"""
import argparse
import datetime
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import random
import re
import shutil
import statistics
import subprocess
import uuid
import zipfile

from observability_bench import source_digest

ROOT = Path(__file__).resolve().parents[1]
SEED = 2026101821


def command(arguments, folder=ROOT):
    return subprocess.run(arguments, cwd=folder, check=True, capture_output=True,
                          encoding='utf-8', timeout=240).stdout.strip()


def build(folder, package='cmd/bench'):
    command(['moon', 'build', '--target', 'native', '--release', package], folder)
    binary = folder / '_build/native/release/build' / package / Path(package).name
    if os.name == 'nt': binary = binary.with_suffix('.exe')
    assert binary.is_file() and binary.resolve().is_relative_to(folder.resolve())
    return str(binary)


def generated_c_digest(folder, package='cmd/bench'):
    data = (folder / '_build/native/release/build' / package / (Path(package).name + '.c')).read_text(encoding='utf-8')
    data = re.sub(r'(?m)^\s*#line[^\n]*\n', '', data)
    data = data.replace(str(folder.resolve()).replace('\\', '\\\\'), '<workspace>')
    return hashlib.sha256(data.encode('utf-8')).hexdigest()


def baseline(ref):
    commit = command(['git', 'rev-parse', '--verify', ref + '^{commit}'])
    assert re.fullmatch('[a-f0-9]{40}', commit)
    folder = ROOT / '.tools' / ('perf-baseline-' + commit[:12])
    assert folder.resolve().is_relative_to((ROOT / '.tools').resolve())
    if not folder.exists():
        archive = subprocess.run(['git', 'archive', '--format=zip', commit], cwd=ROOT,
                                 check=True, capture_output=True).stdout
        folder.mkdir(parents=True)
        with zipfile.ZipFile(io.BytesIO(archive)) as source:
            for item in source.infolist():
                target = folder / item.filename
                assert target.resolve().is_relative_to(folder.resolve())
                if item.is_dir(): target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(source.read(item))
        (folder / '.source-commit').write_text(commit, encoding='utf-8')
    assert (folder / '.source-commit').read_text(encoding='utf-8') == commit
    target = folder / 'cmd/bench'
    target.mkdir(parents=True, exist_ok=True)
    for path in (ROOT / 'cmd/bench').iterdir():
        if path.is_file(): shutil.copyfile(path, target / path.name)
    command(['moon', 'update'], folder)
    binary = build(folder)
    return {'commit': commit, 'source_sha256': source_digest(folder),
            'generated_c_sha256': generated_c_digest(folder), 'binary': binary}


def matrix(smoke):
    if smoke:
        return [
            dict(mode='codec', size=64, entropy='repeat', compressed=compressed, concurrency=1, page_size=0, count=20000)
            for compressed in [False, True]
        ] + [
            dict(mode='lz4', size=64, entropy='repeat', compressed=True, concurrency=1, page_size=0, count=100000),
            dict(mode='read', size=64, entropy='repeat', compressed=True, concurrency=32, page_size=0, count=1024),
            dict(mode='write', size=400000, entropy='random', compressed=True, concurrency=128, page_size=0, count=128),
            dict(mode='page', size=400000, entropy='repeat', compressed=True, concurrency=32, page_size=4, count=128),
        ]
    result = []
    for size in [64, 400000]:
        for entropy in ['repeat', 'random']:
            result.append(dict(mode='lz4', size=size, entropy=entropy, compressed=True,
                               concurrency=1, page_size=0, count=1000000 if size == 64 else 256))
            for compressed in [False, True]:
                result.append(dict(mode='codec', size=size, entropy=entropy, compressed=compressed,
                                   concurrency=1, page_size=0, count=100000 if size == 64 else 256))
                for concurrency in [1, 32, 128]:
                    for mode in ['read', 'write']:
                        result.append(dict(mode=mode, size=size, entropy=entropy, compressed=compressed,
                                           concurrency=concurrency, page_size=0, count=4000 if size == 64 else 256))
                    for page_size in [1, 4, 8]:
                        result.append(dict(mode='page', size=size, entropy=entropy, compressed=compressed,
                                           concurrency=concurrency, page_size=page_size, count=1024 if size == 64 else 128))
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--baseline-ref', default='c37bf22')
    parser.add_argument('--trials', type=int, default=3)
    parser.add_argument('--smoke', action='store_true')
    parser.add_argument('--server-description', default='unspecified; results require environment notes')
    args = parser.parse_args()
    assert 1 <= args.trials <= 20
    previous = baseline(args.baseline_ref)
    current = {'commit': command(['git', 'rev-parse', 'HEAD']),
               'source_sha256': source_digest(ROOT), 'binary': build(ROOT),
               'dirty': bool(command(['git', 'status', '--porcelain']))}
    current['generated_c_sha256'] = generated_c_digest(ROOT)
    folder = ROOT / '.artifacts' / ('performance-' + uuid.uuid4().hex)
    folder.mkdir(parents=True)
    (ROOT / '.artifacts/latest-performance-dir.txt').write_text(str(folder), encoding='utf-8')
    cases = matrix(args.smoke)
    randomizer = random.Random(SEED)
    tasks = [(index, trial) for index in range(len(cases)) for trial in range(args.trials)]
    randomizer.shuffle(tasks)
    records = []
    manifest = {'started_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                'seed': SEED, 'platform': platform.platform(), 'processor': platform.processor(),
                'logical_cpus': os.cpu_count(), 'moon_version': command(['moon', 'version']),
                'moonc_version': command(['moonc', '-v']), 'server_description': args.server_description,
                'authentication': 'password' if os.environ.get('CQL_USERNAME') is not None else 'none',
                'baseline': {key: value for key, value in previous.items() if key != 'binary'},
                'current': {key: value for key, value in current.items() if key != 'binary'},
                'script_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                'trials': args.trials, 'smoke': args.smoke, 'cases': cases,
                'measurement_scope': 'client process; CPU and elapsed exclude setup/warmup; peak memory covers process lifetime; correctness checks included'}
    (folder / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    with (folder / 'records.jsonl').open('w', encoding='utf-8') as output:
        for index, trial in tasks:
            case = cases[index]
            variants = [('baseline', previous), ('current', current)]
            randomizer.shuffle(variants)
            for name, source in variants:
                environment = dict(os.environ, BENCH_MODE=case['mode'], BENCH_SIZE=str(case['size']),
                                   BENCH_ENTROPY=case['entropy'], BENCH_COUNT=str(case['count']),
                                   BENCH_CONCURRENCY=str(case['concurrency']), BENCH_PAGE_SIZE=str(max(1, case['page_size'])),
                                   CQL_COMPRESSION='lz4' if case['compressed'] else 'none', BENCH_CONNECTIONS='1')
                process = subprocess.run([source['binary']], cwd=ROOT, env=environment,
                                         capture_output=True, encoding='utf-8', timeout=240,
                                         creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
                if process.returncode:
                    (folder / f'error-{index}-{trial}-{name}.log').write_text(process.stdout + process.stderr, encoding='utf-8')
                    raise RuntimeError(f'benchmark failed case={index} trial={trial} variant={name}; see {folder}')
                record = json.loads(process.stdout.strip().splitlines()[-1])
                assert record['count'] == case['count'] and record['elapsed_ns'] > 0 and record['peak_memory_bytes'] > 0
                assert record['mode'] == case['mode'] and record['size'] == case['size']
                if case['mode'] not in ['codec', 'lz4']: assert record['server_version'] == '5.0.5'
                record.update(case_id=index, trial=trial, variant=name)
                records.append(record)
                output.write(json.dumps(record) + '\n')
                output.flush()
                print(json.dumps(record), flush=True)
    summary = []
    for index, case in enumerate(cases):
        result = {'case_id': index, **case}
        for variant in ['baseline', 'current']:
            samples = [row for row in records if row['case_id'] == index and row['variant'] == variant]
            result[variant] = {field: statistics.median(row[field] for row in samples) for field in [
                'operations_per_second', 'p50_ns', 'p95_ns', 'p99_ns', 'cpu_percent', 'peak_memory_bytes', 'elapsed_ns']}
        result['elapsed_change_percent'] = (result['current']['elapsed_ns'] / result['baseline']['elapsed_ns'] - 1) * 100
        summary.append(result)
    report = {**manifest, 'completed_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'summary': summary, 'raw': records}
    (folder / 'result.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print('PASS correctness and raw measurements: ' + str(folder / 'result.json'), flush=True)


if __name__ == '__main__':
    main()
