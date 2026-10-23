"""检查用户文档的本地链接、导航覆盖与入门示例一致性。"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent


def main():
    documents = [ROOT / 'README.md', *sorted((ROOT / 'docs').glob('*.md'))]
    failures = []
    readme = (ROOT / 'README.md').read_text(encoding='utf-8')
    quickstart = (ROOT / 'cmd/readme/main.mbt').read_text(encoding='utf-8').removeprefix('///|\n').strip()
    if quickstart not in readme:
        failures.append('README quickstart differs from compiled source')
    for path in documents:
        source = path.read_text(encoding='utf-8')
        for destination in re.findall(r'\]\(([^)]+)\)', source):
            destination = destination.split('#', 1)[0]
            if not destination or '://' in destination:
                continue
            target = (path.parent / destination).resolve()
            if not target.is_relative_to(ROOT) or not target.exists():
                failures.append(f'{path.relative_to(ROOT)}: missing {destination}')
        if path.parent == ROOT / 'docs' and path.name != 'README.md':
            if '[文档目录](README.md)' not in source:
                failures.append(f'{path.name}: missing document navigation')
    index = (ROOT / 'docs/README.md').read_text(encoding='utf-8')
    for path in documents[1:]:
        if path.name != 'README.md' and f']({path.name})' not in index:
            failures.append(f'{path.name}: missing index entry')
    tutorial = (ROOT / 'docs/getting-started.md').read_text(encoding='utf-8')
    source = (ROOT / 'cmd/tutorial/main.mbt').read_text(encoding='utf-8').strip()
    if source not in tutorial:
        failures.append('tutorial source differs from documented runnable example')
    development = (ROOT / 'docs/development-api.md').read_text(encoding='utf-8')
    features = (ROOT / 'cmd/features/main.mbt').read_text(encoding='utf-8').strip()
    if features not in development:
        failures.append('development feature example differs from documented runnable source')
    mapping = (ROOT / 'docs/value-mapping.md').read_text(encoding='utf-8')
    mapping_source = (ROOT / 'cmd/value-mapping/main.mbt').read_text(encoding='utf-8').split('///|\nasync fn main', 1)[0].strip()
    if mapping_source not in mapping:
        failures.append('mapping codec fragment differs from compiled runnable source')
    if failures:
        raise SystemExit('\n'.join(failures))
    print(f'PASS {len(documents)} documents, navigation and runnable tutorial')


if __name__ == '__main__':
    main()
