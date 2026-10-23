"""从 Mooncakes 安装历史版与稳定版；独立项目仅使用已安装的公开 API。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import urllib.request
import uuid

from acceptance_common import ROOT, provenance, run, write_json

SCENARIOS = ['device-events', 'batch-audit', 'data-inspector']


def github_release(version):
    request = urllib.request.Request(f'https://api.github.com/repos/prowk/mooncql/releases/tags/v{version}',
                                     headers={'Accept': 'application/vnd.github+json', 'User-Agent': 'mooncql-package-acceptance'})
    with urllib.request.urlopen(request, timeout=30) as response:
        release = json.load(response)
    assert release['tag_name'] == f'v{version}'
    assert not release['draft'] and not release['prerelease'] and release['published_at']
    return {key: release[key] for key in ['tag_name', 'html_url', 'published_at', 'draft', 'prerelease']}


def normalized(data):
    return data.replace(b'\r\n', b'\n')


def check_package(project, contract, folder):
    package = project / '.mooncakes/prowk/mooncql'
    assert package.is_dir()
    manifest = (package / 'moon.mod').read_text(encoding='utf-8')
    assert 'name = "prowk/mooncql"' in manifest
    assert f'version = "{contract["version"]}"' in manifest
    assert 'license = "Apache-2.0"' in manifest
    assert 'repository = "https://github.com/prowk/mooncql"' in manifest
    tag = 'v' + contract['version']
    commit = run(['git', 'rev-parse', tag + '^{}'], folder, 'tag')
    assert commit == contract['commit'], (tag, commit)
    files = ['LICENSE', 'moon.mod', *[name + '/pkg.generated.mbti' for name in contract['packages']]]
    digests = {}
    for index, name in enumerate(files):
        tagged = run(['git', 'show', f'{tag}:{name}'], folder, f'tag-file-{index}')
        installed = (package / name).read_text(encoding='utf-8')
        assert installed.replace('\r\n', '\n').strip() == tagged.replace('\r\n', '\n').strip(), (tag, name)
        digests[name] = hashlib.sha256(normalized((package / name).read_bytes())).hexdigest()
    # 同时核对运行时源码，避免只比接口而漏掉标签与实际发布内容的偏差。
    runtime = {}
    import subprocess
    for path in sorted(package.rglob('*')):
        if not path.is_file() or path.suffix not in ['.mbt', '.c']:
            continue
        name = path.relative_to(package).as_posix()
        tagged = subprocess.run(['git', 'show', f'{tag}:{name}'], cwd=ROOT, capture_output=True, check=True).stdout
        assert normalized(tagged) == normalized(path.read_bytes()), (tag, name)
        runtime[name] = hashlib.sha256(normalized(path.read_bytes())).hexdigest()
    assert len(runtime) > 20
    return {'commit': commit, 'license': 'Apache-2.0', 'public_api_sha256': digests,
            'runtime_files_checked': len(runtime), 'runtime_sha256': runtime}


def accept_version(folder, contract, execute):
    folder.mkdir(parents=True)
    project = folder / 'consumer'
    project.mkdir()
    version = contract['version']
    (project / 'moon.mod').write_text(
        f'name = "acceptance/consumer"\nversion = "0.0.0"\npreferred_target = "native"\n'
        f'import {{ "prowk/mooncql@{version}", "moonbitlang/async@0.22.3", }}\n', encoding='utf-8')
    (project / 'moon.pkg').write_text('', encoding='utf-8')
    sources = [(scenario, ROOT / 'examples' / scenario) for scenario in SCENARIOS]
    if contract['profile'] == 'stable':
        # README 使用稳定版 Session；不把该接口片段混进 0.1 的历史消费项目。
        sources.append(('readme', ROOT / 'cmd/readme'))
    for scenario, source_directory in sources:
        target = project / scenario
        target.mkdir()
        for name in ['main.mbt', 'moon.pkg']:
            source = (source_directory / name).read_text(encoding='utf-8')
            assert '../' not in source and 'internal/' not in source
            (target / name).write_text(source, encoding='utf-8')
    report = {'version': version, 'profile': contract['profile'], 'passed': False, 'examples_executed': False,
              'readme_compiled': False}
    try:
        # 没有本地 path 依赖，没有符号链接，运行目录是独立模块。
        run(['moon', 'update'], folder, 'update', cwd=project)
        run(['moon', 'check', '--target', 'native', '--deny-warn'], folder, 'check', cwd=project)
        report['package'] = check_package(project, contract, folder)
        report['github_release'] = github_release(version)
        run(['moon', 'build', '--target', 'native', '--deny-warn'], folder, 'build', cwd=project)
        report['readme_compiled'] = contract['profile'] == 'stable'
        if execute:
            environment = dict(os.environ, CQL_EXAMPLE_ROWS='64', CQL_EXAMPLE_ERROR='1')
            environment.pop('CQL_INSPECT_EXISTING', None)
            for scenario in SCENARIOS:
                output = run(['moon', 'run', scenario], folder, scenario, cwd=project, env=environment)
                assert f'PASS scenario={scenario}' in output
                assert 'PASS expected_error=' in output
            environment['CQL_INSPECT_EXISTING'] = '1'
            output = run(['moon', 'run', 'data-inspector'], folder, 'data-inspector-existing', cwd=project, env=environment)
            assert 'existing=true' in output
            report['examples_executed'] = True
        report['passed'] = True
    finally:
        write_json(folder / 'result.json', report)
    print(f'PASS registry {version}: API, license, tag, runtime sources, build; examples={execute}', flush=True)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', action='store_true', help='在专用 Cassandra 上运行三个场景及错误分支')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    output = (args.output or ROOT / '.artifacts' / f'package-acceptance-{uuid.uuid4().hex}').resolve()
    output.mkdir(parents=True, exist_ok=False)
    contracts = json.loads((ROOT / 'fixtures/releases.json').read_text(encoding='utf-8'))
    report = {'passed': False, 'versions': [], 'long_test_run': False}
    try:
        report['provenance'] = provenance(output)
        request = urllib.request.Request('https://api.github.com/repos/prowk/mooncql/releases/latest',
                                         headers={'User-Agent': 'mooncql-package-acceptance'})
        with urllib.request.urlopen(request, timeout=30) as response:
            assert json.load(response)['tag_name'] == 'v' + contracts['stable'], 'update the stable version contract explicitly'
        for contract in contracts['versions']:
            report['versions'].append(accept_version(output / contract['version'], contract, args.run))
        report['passed'] = True
    finally:
        write_json(output / 'result.json', report)
        print(f'Package acceptance artifacts: {output}', flush=True)


if __name__ == '__main__':
    main()
