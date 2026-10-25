"""短时验收公共设施：失败也保存日志和状态，不保存凭据。"""
from datetime import datetime, timezone
import importlib.metadata
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def run(command, folder, name, *, cwd=ROOT, env=None, timeout=240):
    folder.mkdir(parents=True, exist_ok=True)
    process = subprocess.Popen(command, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               encoding='utf-8', errors='replace', start_new_session=os.name != 'nt',
                               creationflags=(subprocess.CREATE_NO_WINDOW | subprocess.CREATE_NEW_PROCESS_GROUP) if os.name == 'nt' else 0)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except BaseException as error:
        # 仅清理本次尚存活的进程组，不按进程名或端口终止其他实例。
        if process.poll() is None:
            if os.name == 'nt':
                subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'],
                               capture_output=True, timeout=20, creationflags=subprocess.CREATE_NO_WINDOW)
            else:
                os.killpg(process.pid, signal.SIGTERM)
        try:
            stdout, stderr = process.communicate(timeout=20)
        except subprocess.TimeoutExpired:
            if os.name != 'nt':
                os.killpg(process.pid, signal.SIGKILL)
            else:
                process.kill()
            stdout, stderr = process.communicate(timeout=20)
        (folder / f'{name}.stdout.log').write_text(stdout or '', encoding='utf-8')
        (folder / f'{name}.stderr.log').write_text(stderr or '', encoding='utf-8')
        if isinstance(error, subprocess.TimeoutExpired):
            raise RuntimeError(f'{name} timed out after {timeout}s; see {folder}') from None
        raise
    (folder / f'{name}.stdout.log').write_text(stdout, encoding='utf-8')
    (folder / f'{name}.stderr.log').write_text(stderr, encoding='utf-8')
    if process.returncode:
        raise RuntimeError(f'{name} exited {process.returncode}; see {folder}')
    return stdout.strip()


def provenance(folder):
    versions = {}
    for package in ['cassandra-driver', 'lz4']:
        try:
            versions[package] = importlib.metadata.version(package)
        except importlib.metadata.PackageNotFoundError:
            versions[package] = None
    paths = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT).decode('utf-8').split('\0')
    digest = hashlib.sha256()
    for name in sorted(set(paths) - {''}):
        path = ROOT / name
        if path.is_file():
            digest.update(name.encode('utf-8') + b'\0')
            digest.update(path.read_bytes().replace(b'\r\n', b'\n') + b'\0')
    return {
        'started_utc': datetime.now(timezone.utc).isoformat(),
        'commit': run(['git', 'rev-parse', 'HEAD'], folder, 'commit'),
        'dirty': bool(run(['git', 'status', '--porcelain', '--untracked-files=normal'], folder, 'status')),
        'source_tree_sha256': digest.hexdigest(),
        'moon': run(['moon', 'version'], folder, 'moon'),
        'moonc': run(['moonc', '-v'], folder, 'moonc'),
        'os': platform.platform(), 'python': platform.python_version(),
        'reference_versions': versions,
    }
