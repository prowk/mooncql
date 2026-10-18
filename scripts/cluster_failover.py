"""逐个停止专用三节点 Cassandra，验证 RF=3/QUORUM、重加入和全部不可用。"""

import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import time
import uuid

from native_runner import ROOT, build_native


def wait_until(predicate, seconds=180):
    until = time.monotonic() + seconds
    while True:
        try:
            if predicate():
                return
        except (subprocess.CalledProcessError, ConnectionError):
            pass
        assert time.monotonic() < until, "Dedicated cluster did not reach expected state"
        time.sleep(1)


class DockerCluster:
    services = ["cassandra1", "cassandra2", "cassandra3"]

    def compose(self, *arguments):
        return subprocess.run(["docker", "compose", "-f", "compose.cluster.yaml", *arguments],
                              cwd=ROOT, check=True, capture_output=True, encoding="utf-8", timeout=180).stdout

    def nodetool(self, index, *arguments):
        return self.compose("exec", "-T", self.services[index], "nodetool", *arguments)

    def status(self, index=0):
        return self.nodetool(index, "status")

    def stop(self, index):
        container = self.compose("ps", "--quiet", self.services[index]).strip()
        assert re.fullmatch(r"[a-f0-9]{12,64}", container)
        result = subprocess.run(["docker", "inspect", container], check=True, capture_output=True, encoding="utf-8")
        networks = json.loads(result.stdout)[0]["NetworkSettings"]["Networks"]
        addresses = [network["IPAddress"] for network in networks.values() if network["IPAddress"]]
        assert len(addresses) == 1
        self.address = str(ipaddress.ip_address(addresses[0]))
        self.compose("stop", self.services[index])

    def wait_down(self, index):
        expression = r"^DN\s+" + re.escape(self.address) + r"\s"
        wait_until(lambda: re.search(expression, self.status((index + 1) % 3), re.M) is not None)

    def start(self, index):
        self.compose("start", self.services[index])

    def wait_up(self, index):
        wait_until(lambda: len(re.findall(r"^UN\s+", self.status(index), re.M)) == 3)

    def repair_auth(self):
        if os.environ.get("CQL_USERNAME"):
            for index in range(3):
                self.nodetool(index, "repair", "-pr", "-full", "system_auth")

    def stop_all(self):
        self.compose("stop")


def exercise(controller):
    binary = build_native("cmd/cluster")
    controller.wait_up(0)
    folder = ROOT / ".artifacts" / ("cluster-failover-" + uuid.uuid4().hex)
    folder.mkdir(parents=True)
    (ROOT / ".artifacts/latest-cluster-dir.txt").write_text(str(folder), encoding="utf-8")
    environment = dict(os.environ, CQL_CLUSTER_DIR=str(folder))
    with (folder / "stdout.log").open("w", encoding="utf-8") as stdout, (folder / "stderr.log").open("w", encoding="utf-8") as stderr:
        process = subprocess.Popen([binary], cwd=ROOT, env=environment, stdout=stdout, stderr=stderr,
                                   creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)

        def marker(name):
            def ready():
                if process.poll() is not None and not (folder / name).exists():
                    raise RuntimeError((folder / "stderr.log").read_text(encoding="utf-8"))
                return (folder / name).exists()
            wait_until(ready)

        try:
            for index in range(3):
                marker(f"ready-{index}")
                if index == 0:
                    controller.repair_auth()
                controller.stop(index)
                controller.wait_down(index)
                (folder / f"down-{index}").write_text("down\n", encoding="utf-8")
                marker(f"checked-{index}")
                print(f"PASS QUORUM with node {index+1} stopped", flush=True)
                controller.start(index)
                controller.wait_up(index)
                (folder / f"up-{index}").write_text("up\n", encoding="utf-8")
            marker("ready-all")
            controller.stop_all()
            (folder / "down-all").write_text("down\n", encoding="utf-8")
            assert process.wait(timeout=30) == 0, (folder / "stderr.log").read_text(encoding="utf-8")
            result = json.loads((folder / "result.json").read_text(encoding="utf-8"))
            assert result == {"cycles": 3, "rows": 88, "active": 0, "waiting": 0}
            print("PASS all-node deadline, independent node generations and drained session", flush=True)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=15)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--docker-compose", action="store_true", required=True)
    parser.parse_args()
    exercise(DockerCluster())
