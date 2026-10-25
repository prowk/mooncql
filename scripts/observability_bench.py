"""同环境随机交错运行旧版本、关闭观测、仅计数和空监听器，记录原始测量。"""

import argparse
import datetime
import io
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import re
import statistics
import subprocess
import zipfile
from benchmark_api import for_baseline

ROOT = Path(__file__).resolve().parent.parent
BASELINE = "2acd8d07a50a206816635e052b74672a8ee29643"


def run(command, folder=ROOT):
    result = subprocess.run(command, cwd=folder, check=True, capture_output=True, encoding="utf-8", timeout=240)
    return result.stdout


def build(folder):
    run(["moon", "build", "--target", "native", "--release", "cmd/observebench"], folder)
    target = folder / "_build/native/release/build/cmd/observebench/observebench"
    if os.name == "nt":
        target = target.with_suffix(".exe")
    assert target.is_file() and target.resolve().is_relative_to(folder.resolve())
    return target


def source_digest(folder):
    digest = hashlib.sha256()
    inputs = []
    for directory, subdirectories, files in os.walk(folder):
        subdirectories[:] = sorted(name for name in subdirectories if name not in {
            ".git", ".tools", ".artifacts", ".mooncakes", "_build", "node_modules"})
        for name in sorted(files):
            path = Path(directory) / name
            if path.suffix in {".mbt", ".c", ".h"} or name in {"moon.mod", "moon.pkg"}:
                inputs.append(path)
    for path in sorted(inputs):
        digest.update(path.relative_to(folder).as_posix().encode("utf-8") + b"\0")
        digest.update(path.read_bytes() + b"\0")
    return digest.hexdigest()


def baseline(ref):
    commit = run(["git", "rev-parse", "--verify", ref + "^{commit}"]).strip()
    assert re.fullmatch(r"[a-f0-9]{40}", commit)
    folder = ROOT / ".tools" / ("observe-baseline-" + commit[:12])
    assert folder.resolve().is_relative_to((ROOT / ".tools").resolve())
    if not folder.exists():
        archive = subprocess.run(["git", "archive", "--format=zip", commit], cwd=ROOT, check=True, capture_output=True).stdout
        folder.mkdir(parents=True)
        with zipfile.ZipFile(io.BytesIO(archive)) as source:
            for entry in source.infolist():
                destination = folder / entry.filename
                assert destination.resolve().is_relative_to(folder.resolve())
                if entry.is_dir():
                    destination.mkdir(parents=True, exist_ok=True)
                else:
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    # 保留源文件原始 UTF-8 字节，测试副本不包含 Git 元数据。
                    destination.write_bytes(source.read(entry))
        (folder / ".source-commit").write_text(commit, encoding="utf-8")
    assert (folder / ".source-commit").read_text(encoding="utf-8") == commit
    target = folder / "cmd/observebench"
    target.mkdir(parents=True, exist_ok=True)
    client_api = (folder / 'client/pkg.generated.mbti').read_text(encoding='utf-8')
    for name in ("main.mbt", "moon.pkg"):
        source = (ROOT / "cmd/observebench" / name).read_text(encoding="utf-8")
        (target / name).write_text(for_baseline(source, client_api), encoding="utf-8")
    # 基准主程序完全相同；旧版本只替换配置工厂，不引用尚不存在的指标 API。
    config = for_baseline((ROOT / "cmd/observebench/config.mbt").read_text(encoding="utf-8"), client_api)
    start = config.index("  let metrics = match mode {")
    constructor = config.index("  let config =", start)
    constructor_end = config.index("\n  )", constructor) + len("\n  )")
    configuration = re.sub(r"(?m)^\s+metrics\?,\n", "", config[constructor:constructor_end])
    config = config[:start] + '  if mode != "off" { fail("baseline only supports off") }\n' + configuration + "\n  (config, () => 0L)\n}\n"
    (target / "config.mbt").write_text(config, encoding="utf-8")
    run(["moon", "update"], folder)
    return build(folder), commit, source_digest(folder)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline-ref", default=BASELINE)
    parser.add_argument("--count", type=int, default=10000)
    parser.add_argument("--trials", type=int, default=5)
    parser.add_argument("--concurrency", type=int, default=32)
    args = parser.parse_args()
    assert 100 <= args.count <= 1000000 and 3 <= args.trials <= 100
    assert 1 <= args.concurrency <= 128
    previous, commit, baseline_digest = baseline(args.baseline_ref)
    current = build(ROOT)
    input_digest = source_digest(ROOT)
    cases = [("baseline", previous, "off"), ("off", current, "off"),
             ("counters", current, "counters"), ("listener", current, "listener")]
    order = random.Random(20261018)
    records = []
    for trial in range(args.trials):
        order.shuffle(cases)
        for name, binary, mode in cases:
            environment = dict(os.environ, OBSERVE_MODE=mode, OBSERVE_COUNT=str(args.count),
                               OBSERVE_CONCURRENCY=str(args.concurrency))
            result = subprocess.run([str(binary)], cwd=ROOT, env=environment, check=True,
                                    capture_output=True, encoding="utf-8", timeout=240)
            record = json.loads(result.stdout.strip().splitlines()[-1])
            assert record["count"] == args.count and record["elapsed_ms"] > 0
            record.update(case=name, trial=trial)
            records.append(record)
            print(json.dumps(record), flush=True)
    summary = {name: statistics.median(record["elapsed_ms"] for record in records if record["case"] == name)
               for name, _, _ in cases}
    output = {"recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "platform": platform.platform(), "processor": platform.processor(),
              "moon_version": run(["moon", "version"]).strip(), "baseline_commit": commit,
              "moonc_version": run(["moonc", "-v"]).strip(),
              "current_commit": run(["git", "rev-parse", "HEAD"]).strip(),
              "current_dirty": bool(run(["git", "status", "--porcelain"]).strip()),
              "current_source_sha256": input_digest, "baseline_source_sha256": baseline_digest,
              "compression": os.environ.get("CQL_COMPRESSION", "none"),
              "count": args.count, "concurrency": args.concurrency, "trials": args.trials,
              "median_ms": summary, "raw": records}
    destination = ROOT / ".artifacts/observability-bench.json"
    destination.write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")
    print("PASS correctness and raw measurements: " + str(destination), flush=True)


if __name__ == "__main__":
    main()
