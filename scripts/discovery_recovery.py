"""专用三节点集群：从单个 seed 发现节点，并实际停止控制连接所属节点。"""

import argparse
import json
import os
import subprocess
import uuid

from cluster_failover import DockerCluster, wait_until
from native_runner import ROOT, build_native


def exercise(controller):
    binary = build_native("cmd/discovery")
    controller.wait_up(0)
    folder = ROOT / ".artifacts" / ("discovery-recovery-" + uuid.uuid4().hex)
    folder.mkdir(parents=True)
    (ROOT / ".artifacts/latest-discovery-dir.txt").write_text(str(folder), encoding="utf-8")
    environment = dict(os.environ, CQL_DISCOVERY_DIR=str(folder),
                       CQL_CLUSTER_NATIVE_HOSTS=",".join(controller.native_hosts()))
    with (folder / "stdout.log").open("w", encoding="utf-8") as stdout, (folder / "stderr.log").open("w", encoding="utf-8") as stderr:
        process = subprocess.Popen([binary], cwd=ROOT, env=environment, stdout=stdout, stderr=stderr,
                                   creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
        victim = None
        stopped = False

        def marker(name):
            def ready():
                if process.poll() is not None and not (folder / name).exists():
                    raise RuntimeError((folder / "stderr.log").read_text(encoding="utf-8"))
                return (folder / name).exists()
            wait_until(ready)

        try:
            marker("ready.json")
            initial = json.loads((folder / "ready.json").read_text(encoding="utf-8"))
            victim = initial["victim"]
            assert isinstance(victim, int) and 0 <= victim < 3
            controller.repair_auth()
            controller.stop(victim)
            stopped = True
            controller.wait_down(victim)
            (folder / "down").write_text("down\n", encoding="utf-8")
            marker("recovered")
            controller.start(victim)
            controller.wait_up(victim)
            stopped = False
            (folder / "up").write_text("up\n", encoding="utf-8")
            assert process.wait(timeout=30) == 0, (folder / "stderr.log").read_text(encoding="utf-8")
            result = json.loads((folder / "result.json").read_text(encoding="utf-8"))
            assert result["discovered"] == 3 and result["control_generation"] > initial["generation"]
            assert result["active"] == result["waiting"] == 0
            print("PASS one seed, metadata match, native address mapping, control node failure/resubscription and drained shutdown", flush=True)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=15)
            if stopped:
                controller.start(victim)
                controller.wait_up(victim)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--docker-compose", action="store_true", required=True)
    parser.parse_args()
    exercise(DockerCluster())
