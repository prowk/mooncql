"""实编译固定稳定版完整记录与穷尽匹配，再独立消费当前候选归档。"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import uuid
import zipfile

from acceptance_common import ROOT, provenance, run, write_json
from package_acceptance import check_package


def stable_source(version):
    api = subprocess.run(['git', 'show', f'v{version}:client/pkg.generated.mbti'], cwd=ROOT,
                         check=True, capture_output=True, encoding='utf-8', timeout=30).stdout
    source = []
    for name in ['Config', 'SessionConfig', 'ExecutionInfo', 'MetricsSnapshot', 'RequestEvent']:
        body = re.search(r'^pub\(all\) struct ' + name + r' \{\n(.*?)^\}', api, re.M | re.S)[1]
        fields = re.findall(r'^\s+(?:mut )?(\w+)\s*:', body, re.M)
        source.append('pub fn copy_' + name.lower() + '(value : @client.' + name + ') -> @client.' + name + ' {\n  {\n' +
                      '\n'.join('    ' + field + ': value.' + field + ',' for field in fields) + '\n  }\n}\n')
    for name in ['DriverError', 'MetricEvent', 'OverloadReason', 'RequestOutcome', 'TimeoutPhase']:
        body = re.search(r'^pub\(all\) (?:enum|suberror) ' + name + r' \{\n(.*?)^\}', api, re.M | re.S)[1]
        patterns = []
        for line in body.splitlines():
            match = re.fullmatch(r'\s+(\w+)(?:\((.*)\))?', line)
            if not match:
                raise ValueError('unsupported stable constructor declaration')
            args = '' if match[2] is None else '(' + ', '.join('_' for _ in match[2].split(',')) + ')'
            patterns.append('    @client.' + match[1] + args + ' => ()')
        source.append('pub fn match_' + name.lower() + '(value : @client.' + name + ') -> Unit {\n  match value {\n' +
                      '\n'.join(patterns) + '\n  }\n}\n')
    source.append('fn main {}\n')
    return '\n///|\n'.join(source)


def copy_example(project, source, name):
    target = project / name
    target.mkdir()
    for path in source.iterdir():
        if path.suffix == '.mbt' and not path.name.endswith(('_test.mbt', '_wbtest.mbt')) or path.name == 'moon.pkg':
            shutil.copyfile(path, target / path.name)


def accept(archive, output):
    contract = json.loads((ROOT / 'fixtures/api-compatibility.json').read_text(encoding='utf-8'))
    version = contract['baseline_version']
    releases = json.loads((ROOT / 'fixtures/releases.json').read_text(encoding='utf-8'))
    stable = next(item for item in releases['versions'] if item['version'] == version)
    project = output / 'consumer'
    project.mkdir(parents=True)
    (project / 'moon.mod').write_text('name = "acceptance/patch-compatibility"\nversion = "0.0.0"\npreferred_target = "native"\n'
                                    f'import {{ "prowk/mooncql@{version}", "moonbitlang/async@0.22.3", }}\n', encoding='utf-8')
    (project / 'moon.pkg').write_text('import { "prowk/mooncql/client", }\npkgtype(kind: "executable")\n', encoding='utf-8')
    (project / 'main.mbt').write_text(stable_source(version), encoding='utf-8')
    copy_example(project, ROOT / 'cmd/readme', 'readme')
    for name in ['device-events', 'batch-audit', 'data-inspector']:
        copy_example(project, ROOT / 'examples' / name, name)
    report = {'passed': False, 'baseline_version': version, 'candidate_is_registry_package': False}
    try:
        report['provenance'] = provenance(output)
        run(['moon', 'update'], output, 'baseline-update', cwd=project)
        run(['moon', 'check', '--target', 'native', '--deny-warn'], output, 'baseline-check', cwd=project)
        report['baseline_package'] = check_package(project, stable, output)
        report['baseline_compiled'] = True
        installed = output / 'candidate'
        assert installed.resolve().is_relative_to(output.resolve())
        installed.mkdir()
        files = []
        with zipfile.ZipFile(archive) as package:
            for item in package.infolist():
                relative = Path(item.filename)
                target = installed / relative
                assert target.resolve().is_relative_to(installed.resolve())
                assert not any(part.startswith('.') for part in relative.parts), item.filename
                assert relative.parts[0] not in ['cmd', 'scripts', 'fixtures', 'examples'], item.filename
                assert relative.name not in ['todo.md', 'TODO.md', 'AGENTS.md'], item.filename
                assert not relative.name.endswith(('_test.mbt', '_wbtest.mbt', '.log')), item.filename
                if not item.is_dir():
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(package.read(item))
                    files.append(item.filename)
        assert 'client/legacy_config.mbt' in files
        report['candidate_archive'] = {'sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
                                       'files': files, 'path': str(archive)}
        for name in ['features', 'profiles', 'limits', 'schema', 'prometheus']:
            copy_example(project, ROOT / 'cmd' / name, name)
        # 原生 workspace 只指向本次解包结果；不改归档版本，也不伪造注册表安装。
        (output / 'moon.work').write_text('members = ["./consumer", "./candidate"]\n', encoding='utf-8')
        run(['moon', 'check', '.', '--target', 'native', '--deny-warn'], output, 'candidate-check', cwd=project)
        run(['moon', 'build', '.', '--frozen', '--target', 'native', '--release', '--deny-warn'], output, 'candidate-build', cwd=project)
        with zipfile.ZipFile(archive) as package:
            assert all((installed / name).read_bytes() == package.read(name) for name in files), 'candidate archive changed during consumption'
        report['candidate_compiled'] = True
        report['passed'] = True
    finally:
        write_json(output / 'result.json', report)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    output = (args.output or ROOT / '.artifacts' / ('patch-compatibility-' + uuid.uuid4().hex)).resolve()
    output.mkdir(parents=True, exist_ok=False)
    version = re.search(r'^version\s*=\s*"([^"]+)"', (ROOT / 'moon.mod').read_text(encoding='utf-8'), re.M)[1]
    archive = args.archive or ROOT / '_build/publish' / f'prowk-mooncql-{version}.zip'
    accept(archive.resolve(), output)
    print(f'PASS stable complete records, exhaustive matches and independent candidate archive: {output}')


if __name__ == '__main__':
    main()
