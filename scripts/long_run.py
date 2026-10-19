"""专用三节点集群上的连续混合读写、周期故障及资源回收验收。"""
import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import statistics
import subprocess
import time
import uuid

from cluster_failover import DockerCluster
from native_runner import ROOT


def runtime_digest():
    paths = [ROOT / name for name in ['moon.mod', 'scripts/long_run.py', 'scripts/cluster_failover.py', 'scripts/native_runner.py']]
    for name in ['client', 'codec', 'framing', 'protocol', 'routing', 'types', 'internal', 'cmd/soak']:
        for path in (ROOT / name).rglob('*'):
            if path.is_file() and (path.suffix in ['.mbt', '.c', '.h'] or path.name == 'moon.pkg'):
                if not path.name.endswith(('_test.mbt', '_wbtest.mbt')):
                    paths.append(path)
    digest = hashlib.sha256()
    for path in sorted(paths):
        digest.update(path.relative_to(ROOT).as_posix().encode('utf-8') + b'\0')
        digest.update(path.read_bytes() + b'\0')
    return digest.hexdigest()


def read_json(path):
    try:
        data = path.read_text(encoding='utf-8')
        return json.loads(data) if data else None
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def trend(samples, field, warmup_ms):
    # 五分钟分桶，按完成请求数拟合，降低瞬时工作集抖动的影响。
    buckets = {}
    for row in samples:
        if row['elapsed_ms'] >= warmup_ms:
            buckets.setdefault(row['elapsed_ms'] // 300000, []).append(row)
    points = [(statistics.median(row['successful'] + row['failed'] for row in rows),
               statistics.median(row[field] for row in rows)) for rows in buckets.values()]
    if len(points) < 4:
        return {'enough_samples': False}
    xs, ys = zip(*points)
    xmean, ymean = statistics.mean(xs), statistics.mean(ys)
    sxx = sum((x - xmean)**2 for x in xs)
    syy = sum((y - ymean)**2 for y in ys)
    assert sxx > 0, 'load made no progress'
    slope = sum((x - xmean) * (y - ymean) for x, y in points) / sxx
    residual = sum((y - ymean - slope * (x - xmean))**2 for x, y in points)
    stderr = math.sqrt(residual / (len(points) - 2) / sxx)
    growth = slope * (max(xs) - min(xs))
    r_squared = 1 - residual / syy if syy else 0
    result = {'enough_samples': True, 'buckets': len(points), 'bytes_per_request': slope,
              'lower_approx_95': slope - 2 * stderr, 'r_squared': r_squared,
              'fitted_growth_bytes': growth, 'first_bucket_bytes': ys[0], 'last_bucket_bytes': ys[-1]}
    # 小幅抖动不作泄漏结论；超过 2 MiB 且线性趋势明显时不通过。
    result['linear_growth_detected'] = growth > 2097152 and slope - 2 * stderr > 0 and r_squared > 0.5
    return result


def analyze(folder, duration_seconds, smoke, faults):
    result = read_json(folder / 'result.json')
    assert result is not None
    samples = [json.loads(line) for line in (folder / 'samples.jsonl').read_text(encoding='utf-8').splitlines()]
    assert len(samples) >= 2
    assert result['load_elapsed_ms'] >= duration_seconds * 1000
    assert result['background_joined'] is True
    assert result['active'] == result['waiting'] == result['pending'] == 0
    assert result['final_metrics']['in_flight'] == result['final_metrics']['waiting'] == 0
    assert result['final_metrics']['in_flight_bytes'] == result['final_metrics']['waiting_bytes'] == 0
    assert result['final_metrics']['connections_established'] == result['final_metrics']['connections_closed']
    assert result['cache_peak'] <= result['cache_capacity']
    for name in ['read', 'write', 'page', 'lwt', 'batch', 'cache', 'schema']:
        assert result['operations'][name] > 0, name
    assert len(faults) >= 1, 'no node fault cycle was completed'
    for previous, current in zip(samples, samples[1:]):
        assert 0 <= current['elapsed_ms'] - previous['elapsed_ms'] <= 120000, 'load heartbeat gap or system suspend'
    windows = {}
    for row in samples:
        windows.setdefault(row['elapsed_ms'] // 300000, []).append(row)
    for rows in windows.values():
        if len(rows) >= 3:
            assert rows[-1]['operations']['read'] > rows[0]['operations']['read']
            assert rows[-1]['operations']['write'] > rows[0]['operations']['write']
    warmup = min(1200000, duration_seconds * 250)
    memory = {field: trend(samples, field, warmup) for field in ['memory_bytes', 'private_bytes']}
    if not smoke:
        assert duration_seconds >= 21600 and len(faults) >= 3
        for value in memory.values():
            assert value['enough_samples'] and not value['linear_growth_detected'], memory
    return {'qualifies_six_hour_run': not smoke and duration_seconds >= 21600,
            'requested_seconds': duration_seconds, 'fault_cycles': len(faults),
            'memory_trends': memory, 'result': result, 'samples': samples, 'faults': faults}


def exercise(controller, duration_seconds=21600, fault_interval=300, down_seconds=15, smoke=False):
    assert duration_seconds >= (120 if smoke else 21600)
    assert 30 <= fault_interval <= 1800 and 1 <= down_seconds <= 60
    assert duration_seconds > fault_interval + 90, 'duration must leave time for a fault and the recovery tail'
    initial_digest = runtime_digest()
    subprocess.run(['moon', 'build', '--target', 'native', '--release', 'cmd/soak'], cwd=ROOT,
                   check=True, capture_output=True, encoding='utf-8', timeout=240)
    binary = ROOT / '_build/native/release/build/cmd/soak/soak'
    if os.name == 'nt': binary = binary.with_suffix('.exe')
    assert binary.is_file() and binary.resolve().is_relative_to(ROOT)
    assert runtime_digest() == initial_digest, 'runtime sources changed during build'
    controller.wait_up(0)
    folder = ROOT / '.artifacts' / ('long-run-' + uuid.uuid4().hex)
    folder.mkdir(parents=True)
    (ROOT / '.artifacts/latest-long-run-dir.txt').write_text(str(folder), encoding='utf-8')
    manifest = {'started_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                'runtime_source_sha256': initial_digest, 'duration_seconds': duration_seconds,
                'smoke': smoke, 'fault_interval': fault_interval, 'down_seconds': down_seconds,
                'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
                'platform': platform.platform(), 'python_version': platform.python_version(),
                'moon_version': subprocess.check_output(['moon', 'version'], cwd=ROOT, encoding='utf-8').strip(),
                'moonc_version': subprocess.check_output(['moonc', '-v'], cwd=ROOT, encoding='utf-8').strip(),
                'controller': type(controller).__name__,
                'authentication': 'password' if os.environ.get('CQL_USERNAME') else 'none',
                'compression': os.environ.get('CQL_COMPRESSION', 'none'),
                'git_dirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, encoding='utf-8').strip()),
                'git_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, encoding='utf-8').strip()}
    (folder / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    environment = dict(os.environ, CQL_SOAK_DIR=str(folder), CQL_SOAK_SECONDS=str(duration_seconds),
                       CQL_CLUSTER_NATIVE_HOSTS=','.join(controller.native_hosts()))
    faults = []
    stopped = None
    with (folder / 'stdout.log').open('w', encoding='utf-8') as stdout, (folder / 'stderr.log').open('w', encoding='utf-8') as stderr:
        process = subprocess.Popen([str(binary)], cwd=ROOT, env=environment, stdout=stdout, stderr=stderr,
                                   creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
        manifest['native_pid'] = process.pid
        (folder / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
        try:
            until = time.monotonic() + 240
            while read_json(folder / 'ready.json') is None:
                assert process.poll() is None, (folder / 'stderr.log').read_text(encoding='utf-8')
                assert time.monotonic() < until, 'long-run fixture not ready'
                time.sleep(0.2)
            controller.repair_auth()
            next_fault = fault_interval * 1000
            deadline = time.monotonic() + duration_seconds + 900
            last_check = 0
            last_elapsed = -1
            last_progress_at = time.monotonic()
            with (folder / 'faults.jsonl').open('w', encoding='utf-8') as fault_output:
                while process.poll() is None:
                    assert time.monotonic() < deadline, 'long-run process deadline'
                    progress = read_json(folder / 'progress.json')
                    if progress and progress['elapsed_ms'] != last_elapsed:
                        last_elapsed = progress['elapsed_ms']
                        last_progress_at = time.monotonic()
                    assert time.monotonic() - last_progress_at <= 120, 'native load stopped reporting progress'
                    if progress and progress['elapsed_ms'] >= next_fault and progress['elapsed_ms'] < (duration_seconds - 90) * 1000:
                        victim = len(faults) % 3
                        fault = {'node': victim, 'start_elapsed_ms': progress['elapsed_ms'],
                                 'started_at': datetime.datetime.now(datetime.timezone.utc).isoformat()}
                        stopped = victim
                        controller.stop(victim)
                        controller.wait_down(victim)
                        down_until = time.monotonic() + down_seconds
                        while time.monotonic() < down_until:
                            assert process.poll() is None, (folder / 'stderr.log').read_text(encoding='utf-8')
                            time.sleep(0.2)
                        controller.start(victim)
                        controller.wait_up(victim)
                        stopped = None
                        fault['restored_at'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
                        faults.append(fault)
                        fault_output.write(json.dumps(fault) + '\n')
                        fault_output.flush()
                        print(json.dumps({'fault_restored': fault, 'cycle': len(faults)}), flush=True)
                        next_fault += fault_interval * 1000
                    if time.monotonic() - last_check >= 60:
                        assert runtime_digest() == initial_digest, 'runtime sources changed during acceptance'
                        last_check = time.monotonic()
                        if progress:
                            print(json.dumps({'progress': progress}), flush=True)
                    time.sleep(0.5)
            assert process.returncode == 0, (folder / 'stderr.log').read_text(encoding='utf-8')
            assert runtime_digest() == initial_digest
            report = {**manifest, **analyze(folder, duration_seconds, smoke, faults),
                      'completed_at': datetime.datetime.now(datetime.timezone.utc).isoformat()}
            (folder / 'report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
            print('PASS long-run validation: ' + str(folder / 'report.json'), flush=True)
            return report
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=15)
            if stopped is not None:
                controller.start(stopped)
                controller.wait_up(stopped)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--docker-compose', action='store_true', required=True)
    parser.add_argument('--seconds', type=int, default=21600)
    parser.add_argument('--fault-interval', type=int, default=300)
    parser.add_argument('--down-seconds', type=int, default=15)
    parser.add_argument('--smoke', action='store_true')
    args = parser.parse_args()
    exercise(DockerCluster(), args.seconds, args.fault_interval, args.down_seconds, args.smoke)
