"""按固定发布资产与校验和预填 Nu 工具缓存，绕过上游安装器的分页查找缺陷。"""
import argparse
import hashlib
import io
import os
from pathlib import Path
import platform
import re
import subprocess
import tarfile
import time
import urllib.request
import zipfile

VERSION = '0.112.2'
BASE = f'https://github.com/nushell/nushell/releases/download/{VERSION}/'


def download(name):
    assert re.fullmatch(r'[A-Za-z0-9_.-]+', name)
    for attempt in range(3):
        try:
            request = urllib.request.Request(BASE + name, headers={'User-Agent': 'mooncql-ci-bootstrap'})
            with urllib.request.urlopen(request, timeout=90) as response:
                data = response.read(160 * 1024 * 1024 + 1)
            assert len(data) <= 160 * 1024 * 1024
            return data
        except (OSError, TimeoutError):
            if attempt == 2:
                raise
            time.sleep(attempt + 1)


def verify_archive(name, data, checksums):
    matches = [parts[0] for line in checksums.splitlines()
               if len(parts := line.split()) == 2 and parts[1].lstrip('*') == name]
    assert len(matches) == 1 and re.fullmatch('[0-9a-fA-F]{64}', matches[0]), 'missing exact checksum'
    assert hashlib.sha256(data).hexdigest() == matches[0].lower(), 'Nushell archive checksum mismatch'


def binary_from_archive(data, windows):
    filename = 'nu.exe' if windows else 'nu'
    if windows:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            entries = [entry for entry in archive.infolist() if Path(entry.filename).name == filename and not entry.is_dir()]
            assert len(entries) == 1
            return archive.read(entries[0])
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
        entries = [entry for entry in archive.getmembers() if Path(entry.name).name == filename and entry.isfile()]
        assert len(entries) == 1
        return archive.extractfile(entries[0]).read()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache-root', type=Path, default=os.environ.get('RUNNER_TOOL_CACHE'))
    args = parser.parse_args()
    assert args.cache_root is not None, 'RUNNER_TOOL_CACHE is required outside explicit local validation'
    assert platform.machine().lower() in ['amd64', 'x86_64'], 'only CI x64 runners are configured'
    assert platform.system() in ['Windows', 'Linux']
    windows = platform.system() == 'Windows'
    cache = args.cache_root.resolve() / 'nushell' / VERSION / 'x64'
    binary = cache / ('nu.exe' if windows else 'nu')
    complete = cache.with_suffix('.complete')
    if not (complete.is_file() and binary.is_file()):
        name = f'nu-{VERSION}-' + ('x86_64-pc-windows-msvc.zip' if windows else 'x86_64-unknown-linux-gnu.tar.gz')
        checksums = download('SHA256SUMS').decode('utf-8')
        data = download(name)
        verify_archive(name, data, checksums)
        # 只写入一个明确命名的普通文件，不按归档路径提取任何目录或链接。
        executable = binary_from_archive(data, windows)
        cache.mkdir(parents=True, exist_ok=True)
        binary.write_bytes(executable)
        if not windows:
            binary.chmod(0o755)
    version = subprocess.check_output([str(binary), '--version'], encoding='utf-8', timeout=20).strip()
    assert version == VERSION, (version, VERSION)
    complete.write_text('', encoding='utf-8')
    print(f'PASS verified Nu {VERSION} tool cache: {cache}')


if __name__ == '__main__':
    main()
