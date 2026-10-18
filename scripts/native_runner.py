"""构建并定位工作区内的原生测试入口，便于直接管理测试进程生命周期。"""

from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def build_native(package):
    source = (ROOT / package).resolve()
    assert source.is_relative_to(ROOT) and (source / "moon.pkg").is_file()
    result = subprocess.run(["moon", "build", "--target", "native", package], cwd=ROOT,
                            capture_output=True, encoding="utf-8", timeout=180)
    if result.returncode:
        raise RuntimeError(result.stdout[-4000:] + result.stderr[-4000:])
    folder = ROOT / "_build/native/debug/build" / package
    for candidate in (folder / (source.name + ".exe"), folder / source.name):
        if candidate.is_file():
            assert candidate.resolve().is_relative_to(ROOT)
            return str(candidate)
    raise RuntimeError("Native test executable was not produced")
