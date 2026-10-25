"""按失败日志重放单轮状态机，并有界缩减并发、取消次数和分片宽度。"""
import argparse
import json
import os
import subprocess
import uuid

from acceptance_common import ROOT, provenance, write_json


def shrink(configuration, fails):
    result = dict(configuration)
    for key, minimum in [('width', 1), ('cancels', 0), ('fragment', 1)]:
        original = result[key]
        for value in dict.fromkeys([minimum, max(minimum, original // 2), max(minimum, original - 1)]):
            if value >= result[key]:
                continue
            candidate = dict(result, **{key: value})
            if fails(candidate):
                result = candidate
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seed', type=int, required=True)
    parser.add_argument('--case', type=int, required=True)
    parser.add_argument('--shrink', action='store_true')
    args = parser.parse_args()
    assert 0 <= args.seed <= 4294967295 and 0 <= args.case <= 255
    folder = ROOT / '.artifacts' / ('model-replay-' + uuid.uuid4().hex)
    folder.mkdir(parents=True)
    report = {'provenance': provenance(folder), 'seed': args.seed, 'case': args.case, 'attempts': [],
              'shrink_scope': 'bounded parameter reduction; not a proof of globally minimal failing trace'}

    def fails(config):
        env = dict(os.environ, CQL_TEST_SEED=str(args.seed), CQL_TEST_CASE=str(args.case), CQL_TEST_ROUNDS=str(args.case + 1),
                   CQL_TEST_WIDTH=str(config['width']), CQL_TEST_CANCELS=str(config['cancels']), CQL_TEST_FRAGMENT=str(config['fragment']))
        process = subprocess.run(['moon', 'test', 'client/state_machine_test.mbt', '--target', 'native', '--deny-warn'],
                                 cwd=ROOT, env=env, capture_output=True, encoding='utf-8', timeout=120,
                                 creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
        name = str(len(report['attempts']))
        (folder / (name + '.stdout.log')).write_text(process.stdout, encoding='utf-8')
        (folder / (name + '.stderr.log')).write_text(process.stderr, encoding='utf-8')
        # 编译错误和构建失败不是已重现的状态机性质失败。
        failed = process.returncode != 0 and 'Total tests:' in process.stdout and 'failed: 0.' not in process.stdout
        report['attempts'].append(dict(configuration=config, exit_code=process.returncode, reproduced=failed))
        write_json(folder / 'result.json', report)
        if process.returncode and not failed:
            raise RuntimeError('model execution failed before test result; see ' + str(folder))
        return failed

    try:
        initial = dict(width=12, cancels=4, fragment=31)
        report['reproduced'] = fails(initial)
        if args.shrink and report['reproduced']:
            report['reduced'] = shrink(initial, fails)
    finally:
        write_json(folder / 'result.json', report)
        print('Model replay report:', folder / 'result.json')


if __name__ == '__main__':
    main()
