"""在本仓库专用 Compose 服务上停止并重启 Cassandra，核对同一 Session 自动恢复。"""

import argparse
import json
import os
import pathlib
import subprocess
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent


def compose(*arguments):
    return subprocess.run(["docker", "compose", *arguments], cwd=ROOT, check=True, timeout=90,
                          capture_output=True, encoding="utf-8").stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--docker-compose", action="store_true", required=True)
    parser.parse_args()
    assert (ROOT / "compose.yaml").is_file()
    assert "cassandra" in compose("config", "--services").splitlines()
    assert compose("ps", "--quiet", "cassandra").strip(), "Start the dedicated Compose service first"
    folder = ROOT / ".artifacts" / ("session-recovery-" + uuid.uuid4().hex)
    folder.mkdir(parents=True)
    environment = dict(os.environ, CQL_RECOVERY_DIR=str(folder))
    with (folder / "stdout.log").open("w", encoding="utf-8") as stdout, (folder / "stderr.log").open("w", encoding="utf-8") as stderr:
        process = subprocess.Popen(["moon", "run", "cmd/recovery"], cwd=ROOT, env=environment,
                                   stdout=stdout, stderr=stderr,
                                   creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
        try:
            until = time.monotonic() + 60
            while not (folder / "ready").exists():
                assert process.poll() is None, (folder / "stderr.log").read_text(encoding="utf-8")
                assert time.monotonic() < until, "Session did not become ready"
                time.sleep(0.1)
            compose("stop", "cassandra")
            (folder / "go").write_text("go\n", encoding="utf-8")
            compose("start", "cassandra")
            assert process.wait(timeout=150) == 0, (folder / "stderr.log").read_text(encoding="utf-8")
            result = json.loads((folder / "result.json").read_text(encoding="utf-8"))
            assert result["generation"] >= 2 and result["active"] == result["waiting"] == 0
            print("PASS real Cassandra restart with unchanged Session and drained tasks")
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=15)


if __name__ == "__main__":
    main()
