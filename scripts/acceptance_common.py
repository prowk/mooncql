"""短时验收公共设施：失败也保存日志和状态，不保存凭据。"""
from datetime import datetime, timezone
import importlib.metadata
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def run(command, folder, name, *, cwd=ROOT, env=None, timeout=240):
    folder.mkdir(parents=True, exist_ok=True)
    try:
        result = subprocess.run(command, cwd=cwd, env=env, capture_output=True,
                                encoding='utf-8', errors='replace', timeout=timeout,
                                creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
    except subprocess.TimeoutExpired as error:
        for suffix, data in [('stdout', error.stdout), ('stderr', error.stderr)]:
            if isinstance(data, bytes):
                data = data.decode('utf-8', errors='replace')
            (folder / f'{name}.{suffix}.log').write_text(data or '', encoding='utf-8')
        raise RuntimeError(f'{name} timed out after {timeout}s; see {folder}') from None
    (folder / f'{name}.stdout.log').write_text(result.stdout, encoding='utf-8')
    (folder / f'{name}.stderr.log').write_text(result.stderr, encoding='utf-8')
    if result.returncode:
        raise RuntimeError(f'{name} exited {result.returncode}; see {folder}')
    return result.stdout.strip()


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
