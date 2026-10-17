"""复现固定版本的 v5 字节样例，可选核验本地参考源码的哈希。"""

import argparse
import hashlib
import json
import pathlib
import zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
COMMIT = "c8abc9f3e1bb46bc4d699c3a167e43df62b9bec8"


def crc24(data):
    crc = 0x875060
    for byte in data:
        crc ^= byte << 16
        for _ in range(8):
            crc <<= 1
            if crc & 0x1000000:
                crc ^= 0x1974F0B
    return crc


def raw_frame(payload, compressed=False):
    # 协商 LZ4 后未压缩的载荷仍使用八字节帧头，解压长度为零。
    width = 5 if compressed else 3
    fields = (len(payload) | (1 << (34 if compressed else 17))).to_bytes(width, "little")
    checksum = zlib.crc32(b"\xfa\x2d\x55\xca" + payload)
    return fields + crc24(fields).to_bytes(3, "little") + payload + checksum.to_bytes(4, "little")


def vectors():
    envelope = bytes.fromhex("050000030700000003") + b"abc"
    return {
        "reference_commit": COMMIT,
        "generator": "python-stdlib zlib.crc32 and explicit little-endian packing",
        "cases": {
            "uncompressed_abc": raw_frame(b"abc").hex(),
            "lz4_raw_abc": raw_frame(b"abc", compressed=True).hex(),
            "query_envelope": envelope.hex(),
            "options_before_startup": "050000000500000000",
            "ready_before_switch": "850000000200000000",
            "options_after_startup": raw_frame(bytes.fromhex("050000000500000000")).hex(),
            "ready_with_extension": "850000000200000003aabbcc",
        },
        "crc32_seeded": {text: zlib.crc32(b"\xfa\x2d\x55\xca" + text.encode("ascii"))
                         for text in ("", "abc", "123456789")},
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--sources", type=pathlib.Path)
    args = parser.parse_args()
    target = ROOT / "fixtures/v5-wire.json"
    expected = vectors()
    if args.write:
        target.write_text(json.dumps(expected, indent=2) + "\n", encoding="utf-8", newline="\n")
    assert json.loads(target.read_text(encoding="utf-8")) == expected
    manifest = json.loads((ROOT / "fixtures/cassandra-5.0.5-reference.json").read_text(encoding="utf-8"))
    assert manifest["commit"] == COMMIT and manifest["tag"] == "cassandra-5.0.5"
    if args.sources:
        for source in manifest["files"]:
            data = (args.sources / pathlib.PurePosixPath(source["path"]).name).read_bytes()
            assert hashlib.sha256(data).hexdigest() == source["sha256"], source["path"]
    print("PASS pinned Cassandra 5.0.5 reference and reproducible v5 wire vectors")


if __name__ == "__main__":
    main()
