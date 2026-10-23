"""发布／消费示例／依赖配置变化时运行完整发布包验收，普通功能提交仅测源码。"""
import json
import os
from pathlib import Path
import re
import subprocess

from native_runner import ROOT


def required():
    if os.environ.get('GITHUB_EVENT_NAME') == 'workflow_dispatch' or os.environ.get('GITHUB_REF', '').startswith('refs/tags/'):
        return True
    event_path = os.environ.get('GITHUB_EVENT_PATH')
    if not event_path:
        return True
    event = json.loads(Path(event_path).read_text(encoding='utf-8'))
    if os.environ.get('GITHUB_EVENT_NAME') == 'pull_request':
        base = event['pull_request']['base']['sha']
        head = event['pull_request']['head']['sha']
    elif os.environ.get('GITHUB_EVENT_NAME') == 'push':
        base, head = event.get('before', ''), event.get('after', '')
    else:
        return True
    if not all(re.fullmatch('[a-f0-9]{40}', sha) and sha != '0' * 40 for sha in (base, head)):
        return True
    result = subprocess.run(['git', 'diff', '--name-only', '-z', base, head, '--'], cwd=ROOT,
                            capture_output=True, timeout=30)
    if result.returncode:
        return True
    paths = result.stdout.decode('utf-8').split('\0')
    relevant = {'README.md', 'docs/getting-started.md', 'docs/versions.md', 'fixtures/releases.json',
                'scripts/package_acceptance.py', 'scripts/package_scope.py'}
    return any(path in relevant or path.startswith('examples/') or Path(path).name in
               {'moon.mod', 'moon.mod.json', 'moon.pkg', 'moon.pkg.json', 'moon.lock'} for path in paths if path)


if __name__ == '__main__':
    value = 'true' if required() else 'false'
    print('Full registry package acceptance required:', value)
    if os.environ.get('GITHUB_OUTPUT'):
        with Path(os.environ['GITHUB_OUTPUT']).open('a', encoding='utf-8') as output:
            output.write('required=' + value + '\n')
