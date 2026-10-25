"""统一短时本地预检与顺序验收；产物仅保存在忽略目录，不运行长测。"""
import argparse
import contextlib
import ctypes
import importlib.metadata
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import uuid

from acceptance_common import ROOT, provenance, run, write_json

GROUPS = ('unit', 'reference', 'single', 'cluster', 'multidc', 'native-tls')
PORTS = {'single': [9042], 'cluster': [19052, 19053, 19054],
         'multidc': [19052, 19053, 19054], 'native-tls': [19064]}


def available_memory():
    if os.name == 'nt':
        class Memory(ctypes.Structure):
            _fields_ = [('length', ctypes.c_ulong), ('load', ctypes.c_ulong)] + [
                (name, ctypes.c_ulonglong) for name in ('total', 'available', 'page_total', 'page_available',
                                                       'virtual_total', 'virtual_available', 'extended')]
        memory = Memory()
        memory.length = ctypes.sizeof(memory)
        if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(memory)):
            return memory.available
    elif Path('/proc/meminfo').exists():
        for line in Path('/proc/meminfo').read_text(encoding='utf-8').splitlines():
            if line.startswith('MemAvailable:'):
                return int(line.split()[1]) * 1024
    return None


def preflight(group):
    problems = []
    for tool in ['git', 'moon', 'moonc'] + (['docker'] if group in PORTS else []):
        if not shutil.which(tool):
            problems.append('missing executable: ' + tool)
    packages = [] if group == 'unit' else ['cassandra-driver', 'lz4', 'cryptography', 'prometheus-client']
    for package in packages:
        try:
            importlib.metadata.version(package)
        except importlib.metadata.PackageNotFoundError:
            problems.append('missing Python package: ' + package)
    # Python 测试也会导入证书与指标参考库。
    if group == 'unit':
        for module in ['cryptography', 'prometheus-client']:
            try:
                importlib.metadata.version(module)
            except importlib.metadata.PackageNotFoundError:
                problems.append('missing Python package: ' + module)
    for port in PORTS.get(group, []):
        with socket.socket() as listener:
            try:
                listener.bind(('127.0.0.1', port))
            except OSError:
                problems.append(f'port {port} is occupied or unavailable; existing instance will not be touched')
    memory = available_memory()
    # 堆外、文件缓存和桌面留出空间；这是保守预检，不将通过预检当成运行证明。
    required = (6 if group in ('cluster', 'multidc') else 3) * 1024 ** 3 if group in PORTS else 0
    if memory is not None and memory < required:
        problems.append(f'available memory {memory} < conservative group requirement {required} bytes')
    if group in PORTS and shutil.which('docker'):
        result = subprocess.run(['docker', 'info', '--format', '{{.MemTotal}}'], capture_output=True,
                                encoding='utf-8', timeout=30)
        if result.returncode:
            problems.append('Docker daemon unavailable')
        elif result.stdout.strip().isdigit() and int(result.stdout.strip()) < required:
            problems.append('Docker memory limit below conservative group requirement')
    return {'group': group, 'available_memory_bytes': memory, 'required_memory_bytes': required,
            'ports': PORTS.get(group, []), 'problems': problems, 'ready': not problems}


@contextlib.contextmanager
def database_lock():
    path = ROOT / '.artifacts/local-database.lock'
    path.parent.mkdir(exist_ok=True)
    with path.open('a+b') as lock:
        lock.seek(0)
        lock.write(b'0')
        lock.flush()
        lock.seek(0)
        if os.name == 'nt':
            import msvcrt
            msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            yield
        finally:
            if os.name == 'nt':
                lock.seek(0)
                msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


def ordinary(group, folder, env):
    commands = ([['moon', 'check', '--target', 'native', '--deny-warn'],
                 ['moon', 'test', '--target', 'native', '--deny-warn'],
                 ['moon', 'test', 'client/state_machine_test.mbt', '--target', 'native', '--deny-warn'],
                 [sys.executable, '-m', 'unittest', 'discover', '-s', 'scripts/tests'],
                 [sys.executable, 'scripts/check_docs.py'], [sys.executable, 'scripts/check_api.py'],
                 ['moon', 'fmt', '--check']]
                if group == 'unit' else [[sys.executable, 'scripts/' + script]
                 for script in ('protocol_reference.py', 'differential.py', 'routing_reference.py', 'tls_matrix.py')])
    for index, command in enumerate(commands):
        step_env = dict(env)
        for name in list(step_env):
            if name.startswith('CQL_TEST_'):
                step_env.pop(name)
        if group == 'unit' and index == 2:
            step_env.update(CQL_TEST_SEED=env['CQL_TEST_SEED'], CQL_TEST_ROUNDS=env['CQL_TEST_ROUNDS'])
        run(command, folder, f'step-{index}', env=step_env, timeout=420)


def database(group, folder, env):
    project = 'mooncql-local-' + uuid.uuid4().hex[:16]
    compose = ['docker', 'compose', '-p', project, '-f', 'compose.yaml' if group == 'single' else 'compose.cluster.yaml']
    if group == 'multidc':
        compose.extend(['-f', 'compose.multidc.yaml'])
    report = {'project': project, 'passed': False, 'cleanup_completed': False}
    try:
        if group == 'native-tls':
            from native_tls_acceptance import DockerController, Fixture, exercise
            fixture = Fixture(folder / 'native-tls')
            server = DockerController(fixture)
            report['project'] = server.project
            exercise(fixture, server)
        elif group == 'single':
            from short_acceptance import accept_case
            for auth in ['none', 'password']:
                group_env = dict(env, CQL_HOST='127.0.0.1', CQL_PORT='9042', CQL_ASSERT_V5_ONLY='1',
                                 CQL_AUTHENTICATOR='AllowAllAuthenticator' if auth == 'none' else 'PasswordAuthenticator')
                if auth == 'password':
                    group_env.update(CQL_USERNAME='cassandra', CQL_PASSWORD='cassandra')
                try:
                    run(compose + ['up', '-d', '--wait', '--wait-timeout', '360'], folder, auth + '-up', env=group_env, timeout=420)
                    for compression in ['none', 'lz4']:
                        accept_case(folder / (auth + '-' + compression), auth, compression, group_env)
                finally:
                    run(compose + ['down', '--volumes'], folder, auth + '-down', env=group_env, timeout=180)
        else:
            # 子程序的所有 compose 调用继承唯一项目名，绝不接管默认项目。
            cluster_env = dict(env, COMPOSE_PROJECT_NAME=project)
            cluster_env.pop('CQL_USERNAME', None)
            cluster_env.pop('CQL_PASSWORD', None)
            cluster_env['CQL_AUTHENTICATOR'] = 'AllowAllAuthenticator'
            cluster_env['CQL_CLUSTER_PORTS'] = '19052,19053,19054'
            run(compose + ['up', '-d', '--wait', '--wait-timeout', '360'], folder, 'up', env=cluster_env, timeout=420)
            scripts = ['cluster_failover.py', 'discovery_recovery.py'] if group == 'cluster' else ['multidc_acceptance.py']
            for script in scripts:
                run([sys.executable, 'scripts/' + script, '--docker-compose'], folder, script, env=cluster_env, timeout=900)
        report['passed'] = True
    finally:
        try:
            if group != 'native-tls':
                run(compose + ['down', '--volumes'], folder, 'final-down', env=env, timeout=180)
                report['cleanup_completed'] = True
            elif (folder / 'native-tls/result.json').is_file():
                report['cleanup_completed'] = json.loads((folder / 'native-tls/result.json').read_text(encoding='utf-8'))['server_stopped']
        finally:
            write_json(folder / 'ownership.json', report)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--group', action='append', choices=GROUPS)
    parser.add_argument('--preflight', action='store_true')
    parser.add_argument('--skip-unavailable', action='store_true')
    parser.add_argument('--seed', type=int, default=2026102501)
    parser.add_argument('--rounds', type=int, default=16)
    args = parser.parse_args()
    if not 0 <= args.seed <= 4294967295 or not 1 <= args.rounds <= 256:
        parser.error('seed must be UInt; rounds must be 1..256')
    folder = ROOT / '.artifacts' / ('local-acceptance-' + uuid.uuid4().hex)
    folder.mkdir(parents=True)
    env = dict(os.environ, CQL_TEST_SEED=str(args.seed), CQL_TEST_ROUNDS=str(args.rounds))
    report = {'passed': False, 'preflight_only': args.preflight, 'seed': args.seed,
              'rounds': args.rounds, 'groups': [], 'long_test_run': False}
    try:
        report['provenance'] = provenance(folder)
        for group in dict.fromkeys(args.group or ['unit']):
            guard = database_lock() if group in PORTS else contextlib.nullcontext()
            with guard:
                check = preflight(group)
                report['groups'].append(check)
                write_json(folder / 'result.json', report)
                if not check['ready']:
                    check['status'] = 'skipped' if args.skip_unavailable else 'failed-preflight'
                    if not args.skip_unavailable:
                        raise RuntimeError('; '.join(check['problems']))
                elif args.preflight:
                    check['status'] = 'ready-not-run'
                else:
                    check['status'] = 'running'
                    target = folder / group
                    if group in PORTS:
                        database(group, target, env)
                    else:
                        ordinary(group, target, env)
                    check['status'] = 'passed'
        report['passed'] = all(check['status'] == 'passed' for check in report['groups']) and not args.preflight
    except BaseException as error:
        report['failure_type'] = type(error).__name__
        if report['groups'] and report['groups'][-1].get('status') == 'running':
            report['groups'][-1]['status'] = 'interrupted' if isinstance(error, KeyboardInterrupt) else 'failed'
        raise
    finally:
        write_json(folder / 'result.json', report)
        print('Local acceptance report:', folder / 'result.json', flush=True)


if __name__ == '__main__':
    main()
