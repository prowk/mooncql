///|
/// 每次连接独立创建的认证会话；令牌只在该次握手中使用。
pub struct Authenticator {
  initial_response : async () -> Bytes?
  evaluate_challenge : async (Bytes?) -> Bytes?
  on_success : async (Bytes?) -> Unit
}

///|
pub fn Authenticator::new(
  initial_response : async () -> Bytes?,
  evaluate_challenge~ : async (Bytes?) -> Bytes? = _ => {
    raise Authentication("challenge not supported")
  },
  on_success~ : async (Bytes?) -> Unit = _ => (),
) -> Authenticator {
  { initial_response, evaluate_challenge, on_success, }
}

///|
/// 每次新建连接时调用工厂，可在此读取更新后的凭据；不得在回调中记录令牌。
pub struct AuthProvider {
  create : async (String, Endpoint) -> Authenticator
}

///|
pub fn AuthProvider::new(
  create : async (String, Endpoint) -> Authenticator,
) -> AuthProvider {
  { create, }
}

///|
/// PasswordAuthenticator 的动态凭据工厂，重连时重新读取用户名与密码。
pub fn AuthProvider::password(
  credentials : async (Endpoint) -> (String, String),
) -> AuthProvider {
  AuthProvider::new((name, endpoint) => {
    if name != "org.apache.cassandra.auth.PasswordAuthenticator" {
      raise Authentication("unsupported server authenticator")
    }
    let (username, password) = credentials(endpoint)
    let token = @codec.Reader::new(
      @protocol.password_auth(username, password).body,
    ).bytes()
    Authenticator::new(() => token)
  })
}

///|
async fn[T] auth_callback(callback : async () -> T) -> T {
  // 认证实现抛出的错误可能含凭据；对外只暴露固定说明，取消仍由任务运行时传递。
  callback() catch {
    _ => raise Authentication("authentication provider failed")
  }
}

///|
fn check_auth_token(token : Bytes?, maximum : Int32) -> Unit raise DriverError {
  if token is Some(token) && token.length() > maximum {
    raise Authentication("authentication token exceeds limit")
  }
}

///|
async fn Connection::authenticate(self : Connection, name : String) -> Unit {
  let provider = match self.config.auth_provider {
    Some(provider) =>
      auth_callback(() => {
        (provider.create)(
          name,
          Endpoint::new(host=self.config.host, port=self.config.port),
        )
      })
    None => {
      if name != "org.apache.cassandra.auth.PasswordAuthenticator" {
        raise Authentication("unsupported server authenticator")
      }
      guard self.config.username is Some(username) &&
        self.config.password is Some(password) else {
        raise Authentication("server requires credentials")
      }
      let request = @protocol.password_auth(username, password) catch {
        _ => raise Authentication("invalid password credentials")
      }
      let token = @codec.Reader::new(request.body).bytes()
      Authenticator::new(() => token)
    }
  }
  let mut token = auth_callback(provider.initial_response)
  for round in 0..<self.config.max_auth_rounds {
    check_auth_token(token, self.config.max_auth_token_bytes)
    match self.handshake_request(@protocol.auth_response(token)).response {
      AuthSuccess(success_token) => {
        check_auth_token(success_token, self.config.max_auth_token_bytes)
        auth_callback(() => (provider.on_success)(success_token))
        return
      }
      AuthChallenge(challenge) => {
        check_auth_token(challenge, self.config.max_auth_token_bytes)
        if round + 1 >= self.config.max_auth_rounds {
          raise Authentication("authentication round limit exceeded")
        }
        token = auth_callback(() => (provider.evaluate_challenge)(challenge))
      }
      Failure(_) => raise Authentication("server rejected authentication")
      _ => raise Authentication("unexpected authentication response")
    }
  }
  raise Authentication("authentication round limit exceeded")
}
