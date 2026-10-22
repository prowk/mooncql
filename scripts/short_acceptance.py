"""严格归档一组或四组短时集成；不运行长测、不操作已有业务表。"""
import argparse
import json
import os
from pathlib import Path
import sys
import uuid

from acceptance_common import ROOT, provenance, run, write_json


def validate_integration(report):
    assert report['rows'] == 10000
    assert report['checksum'] == report['simple_checksum'] == 49995000
    assert report['protocol'] == 5 and report['server'] == '5.0.5'
    assert report['page_size'] == 113
    assert report['simple_pages'] == len(report['page_sizes']) == len(report['terminal_states'])
    assert sum(report['page_sizes']) == 10000
    assert all(type(size) is int and 0 <= size <= 113 for size in report['page_sizes'])
    assert report['terminal_states'][-1] is True
    assert all(state is False for state in report['terminal_states'][:-1])
    assert report['paging_ended'] is True
    assert report['prepared_pages'] > 1
    assert report['large_payload_bytes'] == 400000 and report['large_payload_two_way'] is True
    assert report['batch'] == ['logged', 'unlogged', 'counter']
    for check in ['ttl', 'metadata_updated', 'field_checks']:
        assert report[check] is True, check
    # 页数是固定环境的观察值；不把服务端允许的短页误判为数据错误。
    return {'claimed_pages': 89, 'actual_pages': report['simple_pages'],
            'matches_claim': report['simple_pages'] == 89,
            'conditions': {'server': '5.0.5', 'rows': 10000, 'page_size': 113,
                           'partition': 'device=42', 'concurrent_writers': 32,
                           'fresh_truncated_table': True},
            'correctness': 'all fields ordered, no gaps/duplicates, checksum and terminal paging state'}


def accept_case(folder, auth, compression, environment):
    folder.mkdir(parents=True)
    env = dict(environment, CQL_ROWS='10000', CQL_COMPRESSION=compression,
               CQL_INTEGRATION_REPORT=str(folder / 'integration.json'),
               CQL_INTEROP_REPORT=str(folder / 'interop.json'))
    if auth == 'none':
        env.pop('CQL_USERNAME', None)
        env.pop('CQL_PASSWORD', None)
    else:
        assert env.get('CQL_USERNAME') and env.get('CQL_PASSWORD'), 'password case requires CQL_USERNAME/CQL_PASSWORD'
    report = {'passed': False, 'auth': auth, 'compression': compression}
    try:
        report['provenance'] = provenance(folder)
        run(['moon', 'run', 'cmd/integration'], folder, 'integration', env=env, timeout=360)
        integration = json.loads((folder / 'integration.json').read_text(encoding='utf-8'))
        report['paging'] = validate_integration(integration)
        expected_auth = 'PasswordAuthenticator' if auth == 'password' else 'AllowAllAuthenticator'
        assert integration['authenticator'].endswith(expected_auth), integration['authenticator']
        assert integration['compression'] is (compression == 'lz4')
        run([sys.executable, str(ROOT / 'scripts/interop.py')], folder, 'interop', env=env, timeout=240)
        interop = json.loads((folder / 'interop.json').read_text(encoding='utf-8'))
        assert interop['passed'] is True
        assert interop['moonbit_to_python_rows'] == 10000 and interop['checksum'] == 49995000
        assert interop['python_to_moonbit_to_python'] is True
        assert interop['large_payload_two_way_bytes'] == 400000
        assert interop['protocol'] == 5
        report['passed'] = True
    except Exception as error:
        # 子进程错误只记出口状态，不泄露环境中的密码。
        report['failure'] = f'{type(error).__name__}: {error}'
        raise
    finally:
        write_json(folder / 'result.json', report)
    print(f'PASS {auth}/{compression}: 10000 rows, checksum 49995000, pages={report["paging"]["actual_pages"]}', flush=True)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--auth', choices=['none', 'password'], default='none')
    parser.add_argument('--compression', choices=['none', 'lz4'], default='none')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--docker-matrix', action='store_true', help='启动专用 compose 项目，逐组关闭并清空它自己的卷')
    args = parser.parse_args()
    output = (args.output or ROOT / '.artifacts' / f'short-acceptance-{uuid.uuid4().hex}').resolve()
    output.mkdir(parents=True, exist_ok=False)
    summary = {'passed': False, 'long_test_run': False, 'cases': []}
    try:
        if args.docker_matrix:
            project = 'mooncql-acceptance-' + uuid.uuid4().hex[:10]
            for auth in ['none', 'password']:
                for compression in ['none', 'lz4']:
                    env = dict(os.environ, CQL_AUTHENTICATOR='PasswordAuthenticator' if auth == 'password' else 'AllowAllAuthenticator',
                               CQL_HOST='127.0.0.1', CQL_PORT='9042', CQL_ASSERT_V5_ONLY='1')
                    if auth == 'password':
                        env.update(CQL_USERNAME='cassandra', CQL_PASSWORD='cassandra')
                    command = ['docker', 'compose', '-p', project, '-f', str(ROOT / 'compose.yaml')]
                    name = f'{auth}-{compression}'
                    try:
                        run(command + ['up', '-d', '--wait', '--wait-timeout', '360'], output, name + '-up', env=env, timeout=420)
                        summary['cases'].append(accept_case(output / name, auth, compression, env))
                    finally:
                        try:
                            run(command + ['logs', '--no-color', '--tail=100'], output, name + '-server', env=env)
                        finally:
                            run(command + ['down', '--volumes'], output, name + '-down', env=env)
        else:
            summary['cases'].append(accept_case(output / f'{args.auth}-{args.compression}', args.auth, args.compression, os.environ))
        summary['passed'] = True
    finally:
        write_json(output / 'result.json', summary)
        print(f'Acceptance artifacts: {output}', flush=True)


if __name__ == '__main__':
    main()
