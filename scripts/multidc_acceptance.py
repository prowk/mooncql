"""只操作专用双 DC Compose 集群，隔离 dc1 并验证显式远端回退。"""
import argparse
import json
import os
import subprocess
import uuid

from cluster_failover import DockerCluster, wait_until
from discovery_recovery import verify_routes
from native_runner import ROOT, build_native


class MultiDCCluster(DockerCluster):
    def compose(self, *arguments):
        return subprocess.run(['docker', 'compose', '-f', 'compose.cluster.yaml', '-f', 'compose.multidc.yaml', *arguments],
                              cwd=ROOT, check=True, capture_output=True, encoding='utf-8', timeout=180).stdout


def exercise(controller):
    # 固定无认证测试集群；拒绝从调用环境继承认证或相同端口的其他拓扑配置。
    assert not os.environ.get('CQL_USERNAME') and not os.environ.get('CQL_PASSWORD')
    assert os.environ.get('CQL_CLUSTER_PORTS', '19052,19053,19054') == '19052,19053,19054'
    binary = build_native('cmd/multidc')
    controller.wait_up(0)
    folder = ROOT / '.artifacts' / ('multidc-' + uuid.uuid4().hex)
    folder.mkdir(parents=True)
    environment = dict(os.environ, CQL_MULTIDC_DIR=str(folder),
                       CQL_CLUSTER_NATIVE_HOSTS=','.join(controller.native_hosts()))
    with (folder / 'stdout.log').open('w', encoding='utf-8') as stdout, (folder / 'stderr.log').open('w', encoding='utf-8') as stderr:
        process = subprocess.Popen([binary], cwd=ROOT, env=environment, stdout=stdout, stderr=stderr,
                                   creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
        stopped = False

        def marker(name):
            def reached():
                if process.poll() is not None and not (folder / name).exists():
                    raise RuntimeError((folder / 'stderr.log').read_text(encoding='utf-8'))
                return (folder / name).exists()
            wait_until(reached)

        try:
            marker('ready')
            verify_routes(folder)
            controller.stop(0)
            stopped = True
            controller.wait_down(0)
            (folder / 'down').write_text('down\n', encoding='utf-8')
            marker('isolated')
            controller.start(0)
            controller.wait_up(0)
            stopped = False
            (folder / 'up').write_text('up\n', encoding='utf-8')
            assert process.wait(timeout=70) == 0, (folder / 'stderr.log').read_text(encoding='utf-8')
            result = json.loads((folder / 'result.json').read_text(encoding='utf-8'))
            assert result == dict(passed=True, data_centers=2, nodes=3, replica_checks=64,
                                  remote_fallback=True, local_quorum_preserved=True, resources=0)
            print('PASS two-DC independent replicas, RF refresh, isolated local DC, explicit fallback and drain', flush=True)
            print('Acceptance artifacts:', folder, flush=True)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=15)
            if stopped:
                controller.start(0)
                controller.wait_up(0)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--docker-compose', action='store_true', required=True)
    parser.parse_args()
    exercise(MultiDCCluster())
