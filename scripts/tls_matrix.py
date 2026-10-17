"""生成临时测试证书，使用独立 Python TLS 服务验证原生客户端；可转发真实 Cassandra。"""

import argparse
import asyncio
import datetime
import ipaddress
import json
import os
import pathlib
import ssl
import struct
import subprocess
import zlib

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID
import lz4.block

from protocol_reference import crc24, raw_frame

ROOT = pathlib.Path(__file__).resolve().parent.parent


def certificates(folder):
    folder.mkdir(parents=True, exist_ok=True)
    now = datetime.datetime.now(datetime.timezone.utc)

    def issue(name, parent=None, client=False, expired=False):
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "mooncql-test-" + name)])
        issuer_key, issuer_cert = parent if parent else (key, None)
        builder = (x509.CertificateBuilder().subject_name(subject)
                   .issuer_name(issuer_cert.subject if issuer_cert else subject)
                   .public_key(key.public_key()).serial_number(x509.random_serial_number())
                   .not_valid_before(now - datetime.timedelta(days=30 if expired else 1))
                   .not_valid_after(now + datetime.timedelta(days=-1 if expired else 30))
                   .add_extension(x509.BasicConstraints(ca=parent is None, path_length=None), critical=True))
        if parent:
            builder = builder.add_extension(x509.ExtendedKeyUsage([
                ExtendedKeyUsageOID.CLIENT_AUTH if client else ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
            if not client:
                builder = builder.add_extension(x509.SubjectAlternativeName([
                    x509.DNSName("localhost"), x509.IPAddress(ipaddress.ip_address("127.0.0.1")),
                    x509.IPAddress(ipaddress.ip_address("::1"))]), critical=False)
        cert = builder.sign(issuer_key, hashes.SHA256())
        (folder / f"{name}.pem").write_bytes(cert.public_bytes(serialization.Encoding.PEM))
        (folder / f"{name}.key").write_bytes(key.private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        return key, cert

    ca = issue("ca")
    foreign = issue("foreign-ca")
    issue("server", ca)
    issue("expired-server", ca, expired=True)
    for name, parent in (("client", ca), ("foreign-client", foreign)):
        key, cert = issue(name, parent, client=True)
        (folder / f"{name}.pfx").write_bytes(pkcs12.serialize_key_and_certificates(
            name.encode("ascii"), key, cert, [parent[1]], serialization.NoEncryption()))


def string(value):
    data = value.encode("utf-8")
    return struct.pack(">H", len(data)) + data


def windows_certificate(folder, identity, remove=False):
    cert = x509.load_pem_x509_certificate((folder / f"{identity}.pem").read_bytes())
    thumbprint = cert.fingerprint(hashes.SHA1()).hex().upper()
    environment = dict(os.environ, MOONCQL_TEST_THUMBPRINT=thumbprint,
                       MOONCQL_TEST_PFX=str(folder / f"{identity}.pfx"))
    setup = r"""
chcp 65001 > $null
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$ErrorActionPreference = 'Stop'
$store = [Security.Cryptography.X509Certificates.X509Store]::new('My', 'CurrentUser')
$store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
$found = $store.Certificates.Find([Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint, $env:MOONCQL_TEST_THUMBPRINT, $false)
"""
    if remove:
        action = r"""
try {
  if ($found.Count -ne 1) { throw 'Expected one owned test certificate' }
  $certificate = $found[0]
  if ($certificate.Subject -notlike 'CN=mooncql-test-*') { throw 'Unexpected test certificate subject' }
  $privateKey = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certificate)
  $store.Remove($certificate)
  if ($privateKey -is [Security.Cryptography.RSACng]) {
    $privateKey.Key.Delete()
  } elseif ($privateKey -is [Security.Cryptography.RSACryptoServiceProvider]) {
    $privateKey.PersistKeyInCsp = $false
    $privateKey.Clear()
  } else { throw 'Unexpected owned test key provider' }
  $privateKey.Dispose()
  $certificate.Dispose()
} finally { $store.Close() }
"""
    else:
        action = r"""
try {
  if ($found.Count -ne 0) { throw 'Test certificate already exists' }
  $flags = [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::UserKeySet -bor [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet
  $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($env:MOONCQL_TEST_PFX, '', $flags)
  if ($certificate.Thumbprint -ne $env:MOONCQL_TEST_THUMBPRINT) { throw 'Unexpected imported test certificate' }
  $store.Add($certificate)
  $certificate.Dispose()
} finally { $store.Close() }
"""
    result = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", setup + action],
                            env=environment, capture_output=True, encoding="utf-8", timeout=30)
    if result.returncode:
        raise RuntimeError(result.stderr[-4000:])
    return thumbprint


def envelope(stream, opcode, body):
    return struct.pack(">BBhBI", 0x85, 0, stream, opcode, len(body)) + body


def frame(payload, compressed):
    candidate = lz4.block.compress(payload, store_size=False) if compressed else payload
    if not compressed or len(candidate) >= len(payload):
        return raw_frame(payload, compressed)
    fields = (len(candidate) | (len(payload) << 17) | (1 << 34)).to_bytes(5, "little")
    return (fields + crc24(fields).to_bytes(3, "little") + candidate
            + zlib.crc32(b"\xfa\x2d\x55\xca" + candidate).to_bytes(4, "little"))


async def read_envelope(reader, compressed=None, pending=None):
    if compressed is None:
        header = await reader.readexactly(9)
        version, flags, stream, opcode, length = struct.unpack(">BBhBI", header)
        assert version == 5 and flags == 0 and length <= 16777216
        return stream, opcode, await reader.readexactly(length)
    while len(pending) < 9 or len(pending) < 9 + int.from_bytes(pending[5:9], "big"):
        width = 5 if compressed else 3
        header = await reader.readexactly(width + 3)
        assert crc24(header[:width]) == int.from_bytes(header[width:], "little")
        bits = int.from_bytes(header[:width], "little")
        length = bits & 0x1FFFF
        uncompressed = (bits >> 17) & 0x1FFFF if compressed else 0
        payload = await reader.readexactly(length)
        assert zlib.crc32(b"\xfa\x2d\x55\xca" + payload) == int.from_bytes(await reader.readexactly(4), "little")
        if uncompressed:
            payload = lz4.block.decompress(payload, uncompressed_size=uncompressed)
        pending.extend(payload)
        assert len(pending) <= 16777225
    version, flags, stream, opcode, length = struct.unpack(">BBhBI", pending[:9])
    assert version == 5 and flags == 0
    body = bytes(pending[9:9 + length])
    del pending[:9 + length]
    return stream, opcode, body


async def mock(reader, writer, delay):
    jobs = []
    try:
        stream, opcode, _ = await read_envelope(reader)
        assert opcode == 5
        supported = b"\x00\x02" + string("CQL_VERSION") + b"\x00\x01" + string("3.0.0")
        supported += string("COMPRESSION") + b"\x00\x01" + string("lz4")
        writer.write(envelope(stream, 6, supported))
        await writer.drain()
        stream, opcode, startup = await read_envelope(reader)
        assert opcode == 1
        compressed = b"lz4" in startup
        writer.write(envelope(stream, 2, b""))
        await writer.drain()
        pending = bytearray()

        async def respond(stream, name, value):
            await asyncio.sleep(delay)
            body = struct.pack(">iii", 2, 1, 1) + string("system") + string("local") + string(name)
            body += b"\x00\x0d" + struct.pack(">ii", 1, len(value)) + value
            message = envelope(stream, 8, body)
            for start in range(0, len(message), 131071):
                # 大消息的分片不得标为自包含。
                part = message[start:start + 131071]
                if len(message) <= 131071:
                    writer.write(frame(part, compressed))
                else:
                    wire = bytearray(raw_frame(part, compressed))
                    width = 5 if compressed else 3
                    fields = (int.from_bytes(wire[:width], "little") & ~(1 << (34 if compressed else 17))).to_bytes(width, "little")
                    wire[:width + 3] = fields + crc24(fields).to_bytes(3, "little")
                    writer.write(wire)
            await writer.drain()

        while True:
            stream, opcode, body = await read_envelope(reader, compressed, pending)
            assert opcode == 7
            length = int.from_bytes(body[:4], "big")
            cql = body[4:4 + length].decode("utf-8")
            if "blobAsVarchar" in cql:
                offset = 4 + length + 6
                assert int.from_bytes(body[offset:offset + 2], "big") == 1
                size = int.from_bytes(body[offset + 2:offset + 6], "big")
                value = body[offset + 6:offset + 6 + size]
                assert len(value) == size == 400000
                jobs.append(asyncio.create_task(respond(stream, "value", value)))
            else:
                jobs.append(asyncio.create_task(respond(stream, "release_version", b"5.0.5")))
    except (asyncio.IncompleteReadError, ConnectionError, ssl.SSLError):
        pass
    finally:
        for job in jobs:
            job.cancel()
        await asyncio.gather(*jobs, return_exceptions=True)
        writer.close()
        try:
            await writer.wait_closed()
        except (ConnectionError, ssl.SSLError):
            pass


async def proxy(reader, writer, backend, delay):
    upstream_writer = None
    jobs = []
    try:
        upstream_reader, upstream_writer = await asyncio.open_connection("127.0.0.1", backend)

        async def copy(source, target, pause):
            while data := await source.read(65536):
                if pause:
                    await asyncio.sleep(pause)
                target.write(data)
                await target.drain()

        jobs = [asyncio.create_task(copy(reader, upstream_writer, 0)),
                asyncio.create_task(copy(upstream_reader, writer, delay))]
        await asyncio.wait(jobs, return_when=asyncio.FIRST_COMPLETED)
    finally:
        for job in jobs:
            job.cancel()
        await asyncio.gather(*jobs, return_exceptions=True)
        for endpoint in (upstream_writer, writer):
            if endpoint:
                endpoint.close()
                try:
                    await endpoint.wait_closed()
                except (ConnectionError, ssl.SSLError):
                    pass


async def matrix(args):
    folder = (ROOT / ".tools/tls-fixtures").resolve()
    certificates(folder)
    cases = [
        ("valid-dns", "server", "localhost", "ca", None, False, False),
        ("valid-ip", "server", "127.0.0.1", "ca", None, False, False),
        ("wrong-host", "server", "wrong.invalid", "ca", None, False, True),
        ("untrusted-ca", "server", "localhost", "foreign-ca", None, False, True),
        ("expired", "expired-server", "localhost", "ca", None, False, True),
        ("mutual", "server", "localhost", "ca", "client", True, False),
        ("missing-client", "server", "localhost", "ca", None, True, True),
        ("untrusted-client", "server", "localhost", "ca", "foreign-client", True, True),
        ("cancel-late", "server", "localhost", "ca", "client", True, False),
    ]
    report = []
    for name, certificate, hostname, trust, identity, mutual, failure in cases:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(folder / f"{certificate}.pem", folder / f"{certificate}.key")
        if mutual:
            context.verify_mode = ssl.CERT_REQUIRED
            context.load_verify_locations(folder / "ca.pem")
        delay = 0.3 if name == "cancel-late" else 0
        accepted = 0

        async def handle(reader, writer):
            nonlocal accepted
            accepted += 1
            if mutual:
                assert writer.get_extra_info("peercert")
            if args.backend_port:
                await proxy(reader, writer, args.backend_port, delay)
            else:
                await mock(reader, writer, delay)

        async with await asyncio.start_server(handle, "127.0.0.1", 0, ssl=context) as server:
            environment = dict(os.environ)
            for key in list(environment):
                if key.startswith("CQL_TLS_"):
                    del environment[key]
            environment.update(CQL_PORT=str(server.sockets[0].getsockname()[1]), CQL_TLS_CA=str(folder / f"{trust}.pem"),
                               CQL_TLS_NAME=hostname, CQL_TLS_EXPECT_FAIL="1" if failure else "0",
                               CQL_COMPRESSION=os.environ.get("CQL_COMPRESSION", "lz4"))
            if not args.backend_port:
                environment.pop("CQL_USERNAME", None)
                environment.pop("CQL_PASSWORD", None)
            if identity:
                if os.name == "nt":
                    environment["CQL_TLS_CLIENT_THUMBPRINT"] = await asyncio.to_thread(windows_certificate, folder, identity)
                else:
                    environment["CQL_TLS_CLIENT_CERT"] = str(folder / f"{identity}.pem")
                    environment["CQL_TLS_CLIENT_KEY"] = str(folder / f"{identity}.key")
            if name == "cancel-late":
                environment["CQL_TLS_CANCEL"] = "1"
            if not failure and name != "cancel-late":
                environment["CQL_TLS_LARGE"] = "1"
            try:
                result = await asyncio.to_thread(subprocess.run, ["moon", "run", "cmd/tlscheck"], cwd=ROOT,
                                                 env=environment, capture_output=True, encoding="utf-8", timeout=60)
            finally:
                if identity and os.name == "nt":
                    await asyncio.to_thread(windows_certificate, folder, identity, True)
            if result.returncode:
                raise RuntimeError(f"{name}: {result.stdout[-4000:]}\n{result.stderr[-4000:]}")
            if name in ("missing-client", "untrusted-client"):
                assert accepted == 0, "TLS server accepted invalid client credentials"
            print(f"PASS TLS {name}", flush=True)
            report.append({"case": name, "status": "passed"})
    destination = ROOT / ".artifacts/tls-matrix.json"
    destination.parent.mkdir(exist_ok=True)
    destination.write_text(json.dumps({"backend": "Cassandra" if args.backend_port else "independent Python mock",
                                      "platform": os.name, "cases": report}, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend-port", type=int)
    asyncio.run(matrix(parser.parse_args()))
