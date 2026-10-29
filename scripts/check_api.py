"""对照固定稳定标签检查公开声明差异；私有字段不当作外部可构造 API。"""
import argparse
import hashlib
import json
import re
import subprocess

from native_runner import ROOT

CONTRACT = ROOT / 'fixtures/api-compatibility.json'


def canonical_types(source):
    # 新工具链把内建 Int／UInt 显示为 Int32／UInt32；只统一类型表达式。
    # 保留限定类型和具名参数标签，不能掩盖用户类型或参数改名。
    return re.sub(r'(?<![\w.@])(?:Int32|UInt32)\b(?!\s*[?~]?\s*:)',
                  lambda match: {'Int32': 'Int', 'UInt32': 'UInt'}[match[0]], source)


def canonical_member(line):
    method = re.match(r'^\s*(?:async )?fn(?:\[[^\n]*?\])? ([^\s(]+)', line)
    if method:
        return line[:method.end()] + canonical_types(line[method.end():])
    if ' : ' in line:
        label, expression = line.split(' : ', 1)
        return label + ' : ' + canonical_types(expression)
    if '(' in line:
        # 枚举分支名保持原样，只统一其载荷类型。
        constructor, expression = line.split('(', 1)
        return constructor + '(' + canonical_types(expression)
    return line


def declarations(source):
    result = {}
    lines = source.replace('\r\n', '\n').splitlines()
    index = 0
    while index < len(lines):
        line = lines[index]
        function = re.match(r'^pub (?:async )?fn(?:\[[^\n]*?\])? ([^\s(]+)', line)
        typ = re.match(r'^pub(?:\(all\))? (struct|enum|suberror|type|trait) ([A-Za-z_][A-Za-z_0-9]*)', line)
        if function:
            key = 'fn ' + function[1]
            signature = line[:function.end()] + canonical_types(line[function.end():])
        elif line.startswith('pub impl '):
            key, signature = line.removeprefix('pub '), line
        elif typ:
            key, signature = 'type ' + typ[2], line
            if '{' in line:
                body = []
                while not lines[index].startswith('}'):
                    index += 1
                    if index >= len(lines):
                        raise ValueError('unterminated exported type')
                    body.append(lines[index])
                if line.startswith('pub(all)') or typ[1] == 'trait':
                    signature += '\n' + '\n'.join(canonical_member(member) for member in body)
                # pub struct 的字段对消费者不可见，只保留不透明类型头。
        else:
            if line.startswith('pub ') or line.startswith('pub('):
                raise ValueError('unsupported public declaration: ' + line)
            index += 1
            continue
        if key in result:
            raise ValueError('duplicate exported symbol: ' + key)
        result[key] = signature
        index += 1
    return result


def digest(value):
    return hashlib.sha256(value.encode('utf-8')).hexdigest()


def git(*arguments):
    return subprocess.run(['git', *arguments], cwd=ROOT, check=True, capture_output=True, encoding='utf-8', timeout=30).stdout.strip()


def audit():
    versions = json.loads((ROOT / 'fixtures/releases.json').read_text(encoding='utf-8'))
    stable = next(version for version in versions['versions'] if version['version'] == versions.get('api_baseline', versions['stable']))
    tag = 'v' + stable['version']
    assert git('rev-parse', tag + '^{}') == stable['commit'], 'stable API baseline tag moved'
    packages = sorted(set(stable['packages']) | {path.parent.name for path in ROOT.glob('*/pkg.generated.mbti') if not path.parent.name.startswith('.')})
    report = dict(baseline_version=stable['version'], baseline_commit=stable['commit'], packages=packages, added=[], changed=[], removed=[])
    for package in packages:
        current = declarations((ROOT / package / 'pkg.generated.mbti').read_text(encoding='utf-8'))
        previous = declarations(git('show', tag + ':' + package + '/pkg.generated.mbti')) if package in stable['packages'] else {}
        for symbol in sorted(current.keys() | previous.keys()):
            if symbol not in previous:
                report['added'].append(dict(package=package, symbol=symbol, signature_sha256=digest(current[symbol])))
            elif symbol not in current:
                report['removed'].append(dict(package=package, symbol=symbol, signature=previous[symbol]))
            elif current[symbol] != previous[symbol]:
                report['changed'].append(dict(package=package, symbol=symbol, before=previous[symbol], after=current[symbol], migration='docs/migration.md'))
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--update', action='store_true', help='源码和迁移文档审核后更新声明差异合同')
    args = parser.parse_args()
    report = audit()
    assert not report['removed'], 'removing a stable public declaration requires a separately reviewed versioned migration'
    assert not report['changed'], 'patch release must preserve stable declarations; use separate additive APIs for extended options'
    migration = (ROOT / 'docs/migration.md').read_text(encoding='utf-8')
    for change in report['changed']:
        owner = change['symbol'].split(' ', 1)[1].split('::', 1)[0]
        assert owner in migration, 'missing migration discussion for ' + change['symbol']
    if args.update:
        CONTRACT.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    expected = json.loads(CONTRACT.read_text(encoding='utf-8'))
    assert report == expected, 'public API differs from reviewed contract; inspect generated interfaces and migration before --update'
    output = ROOT / '.artifacts/api-compatibility/result.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(dict(passed=True, **report), ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'PASS public API against {report["baseline_version"]}: {len(report["added"])} added, {len(report["changed"])} changed, 0 removed')


if __name__ == '__main__':
    main()
