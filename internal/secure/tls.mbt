// 修改声明：prowk/mooncql 基于 moonbitlang/async 0.22.3 修改。
// 隔离 FFI 符号，补充经证书与名称验证的客户端 TLS 及凭据适配。来源及上游原始哈希见 internal/secure/NOTICE.md 和 UPSTREAM.json。

// Copyright 2025 International Digital Economy Academy
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

///|
pub suberror TlsError {
  TlsError(String)
} derive(Debug, ToJson)

///|
pub suberror ConnectionClosed derive(Debug, ToJson)

///|
const PEM_BEGIN = "-----BEGIN CERTIFICATE-----"

///|
const PEM_END = "-----END CERTIFICATE-----"

///|
// Wasm TLS dispatches server credential shape from the host runtime platform.
let _target_specific_imports : Unit = ignore(@async.platform)

///|
fn decode_pem_certificates(pem : String) -> Array[Bytes] raise TlsError {
  let certs = []
  for chunk in pem.split(PEM_BEGIN) {
    match chunk.split_once(PEM_END) {
      None => ()
      Some((base64_body, _)) => {
        let cert = @base64.decode(base64_body.trim(), ignore_whitespace=true) catch {
          _ =>
            raise TlsError(
              "invalid PEM certificate in custom root certificate file",
            )
        }
        certs.push(cert)
      }
    }
  }
  guard !certs.is_empty() else {
    raise TlsError("no PEM certificate found in custom root certificate file")
  }
  certs
}

///|
/// Specify the trusted root when performing TLS certificate validation.
///
/// - `NoVerification`: disable certificate validation.
///   This destroys the whole purpose of using TLS and should only be used for testing purpose.
///
/// - `SystemRoot`: use the default trusted root of the system
///
/// - `CustomPemFile(name)`: use the certificates in the PEM file `name` exclusively as trusted root.
///   Useful for connecting to services whose certificates are issued by a private or self-signed root.
pub(all) enum TrustedRoot {
  NoVerification
  SystemRoot
  CustomPemFile(String)
}

///|
pub(all) enum X509FileType {
  PEM = 1
  ANS1 = 2
}

///|
/// Create a TLS client that read from write to `inner`.
/// `client` will block until TLS handshake to remote server completed.
///
/// `trust` specifies which servers are trusted and how certificate validation is performed.
/// See `TrustedRoot` for more details. The default is `SystemRoot`.
///
/// If `host` is present, it will be used to verify the peer's certificate.
///
/// If `host` is present and `sni` is `true` (`true` by default),
/// Server Name Indication (SNI) field of TLS will be set to `host`.
/// `sni=false` is currently unsupported on Windows.
#label_migration(verify, fill=false, msg="use `trust` instead")
pub async fn[Inner : @io.Reader + @io.Writer] Tls::client(
  inner : Inner,
  verify~ : Bool = true,
  host? : String,
  sni~ : Bool = true,
  trust? : TrustedRoot,
  identity? : ClientIdentity,
) -> Tls {
  let trust = match trust {
    Some(trust) => trust
    None => if verify { SystemRoot } else { NoVerification }
  }
  Tls::client_from_pair(inner, inner, host?, sni~, trust~, identity?)
}

///|
pub(all) enum ClientIdentity {
  Pem(String, String)
  WindowsStore(String)
}

///|
pub extend TlsError with @debug.Debug::{to_repr}

///|
pub extend TlsError with ToJson::{to_json}

///|
pub extend ConnectionClosed with @debug.Debug::{to_repr}

///|
pub extend ConnectionClosed with ToJson::{to_json}

///|
#cfg(platform="windows")
fn platform_error(code : Int32) -> String {
  "TLS platform error: \{code}"
}

///|
pub async fn Tls::read_exactly(self : Tls, length : Int32) -> Bytes {
  if length < 0 {
    raise TlsError("negative read length")
  }
  let buffer = FixedArray::make(length, b'\x00')
  let mut offset = 0
  while offset < length {
    let received = self.read_raw(buffer, offset~, max_len=length - offset)
    if received <= 0 {
      raise ConnectionClosed
    }
    offset += received
  }
  buffer.unsafe_reinterpret_as_bytes()
}

///|
pub async fn Tls::read_some(self : Tls) -> Bytes? {
  let buffer = FixedArray::make(8192, b'\x00')
  let length = self.read_raw(buffer, offset=0, max_len=8192)
  if length == 0 {
    None
  } else {
    Some(buffer.unsafe_reinterpret_as_bytes()[0:length].to_owned())
  }
}

///|
pub async fn Tls::write(self : Tls, bytes : Bytes) -> Unit {
  let mut offset = 0
  while offset < bytes.length() {
    let length = self.write_once(bytes, offset~, len=bytes.length() - offset)
    if length <= 0 {
      raise ConnectionClosed
    }
    offset += length
  }
}
