///|
pub(all) enum ClientIdentity {
  Pem(String, String)
  WindowsStore(String)
}

///|
pub(all) struct TlsConfig {
  server_name : String?
  ca_file : String?
  identity : ClientIdentity?
}

///|
pub fn TlsConfig::new(
  server_name? : String,
  ca_file? : String,
  identity? : ClientIdentity,
) -> TlsConfig {
  { server_name, ca_file, identity, }
}

///|
struct Transport {
  tcp : @socket.Tcp
  tls : @secure.Tls?
  mut closed : Bool
}

///|
fn validate_tls_name(value : String) -> Unit raise DriverError {
  if value.is_empty() {
    raise Configuration("empty TLS name or path")
  }
  for byte in @utf8.encode(value) {
    if byte == b'\x00' {
      raise Configuration("NUL in TLS name or path")
    }
  }
}

///|
async fn Transport::connect(config : ConnectionBuilder) -> Transport {
  let tcp = @socket.Tcp::connect_to_host(config.host, port=config.port)
  let mut ready = false
  defer (if !ready { tcp.close() })
  let tls = match config.tls {
    None => None
    Some(options) => {
      let server_name = options.server_name.unwrap_or(config.host)
      validate_tls_name(server_name)
      let trust = match options.ca_file {
        None => @secure.TrustedRoot::SystemRoot
        Some(path) => {
          validate_tls_name(path)
          CustomPemFile(path)
        }
      }
      let identity = match options.identity {
        None => None
        Some(Pem(certificate, private_key)) => {
          validate_tls_name(certificate)
          validate_tls_name(private_key)
          Some(@secure.ClientIdentity::Pem(certificate, private_key))
        }
        Some(WindowsStore(thumbprint)) => {
          validate_tls_name(thumbprint)
          Some(@secure.ClientIdentity::WindowsStore(thumbprint))
        }
      }
      Some(@secure.Tls::client(tcp, host=server_name, trust~, identity?)) catch {
        @secure.TlsError(message) => raise TlsFailure(message)
        @secure.ConnectionClosed => raise Closed
        error => raise error
      }
    }
  }
  ready = true
  { tcp, tls, closed: false, }
}

///|
fn Transport::close(self : Transport) -> Unit {
  if !self.closed {
    self.closed = true
    if self.tls is Some(tls) {
      tls.close()
    }
    self.tcp.close()
  }
}

///|
async fn Transport::read_exactly(self : Transport, length : Int) -> Bytes {
  if self.closed {
    raise Closed
  }
  try {
    match self.tls {
      Some(tls) => tls.read_exactly(length)
      None => self.tcp.read_exactly(length)
    }
  } catch {
    @secure.TlsError(message) => raise TlsFailure(message)
    @secure.ConnectionClosed => raise Closed
    error => raise error
  }
}

///|
async fn Transport::write(self : Transport, bytes : Bytes) -> Unit {
  if self.closed {
    raise Closed
  }
  try {
    match self.tls {
      Some(tls) => tls.write(bytes)
      None => self.tcp.write(bytes)
    }
  } catch {
    @secure.TlsError(message) => raise TlsFailure(message)
    @secure.ConnectionClosed => raise Closed
    error => raise error
  }
}
