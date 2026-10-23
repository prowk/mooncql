///|
async fn main {
  @client.with_session(session => {
    guard session.query("SELECT release_version FROM system.local")
      is Rows(page) else {
      fail("expected server version")
    }
    println(page.row(0).text("release_version"))
  })
}
