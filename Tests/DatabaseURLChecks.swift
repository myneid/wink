import Foundation

@main struct Checks {
  static func main() throws {
    var count = 0
    func check(_ condition: Bool, _ note: String = "", line: Int = #line) {
      if !condition { print("FAIL line \(line) \(note)"); exit(1) }
      count += 1
    }
    let hosts = [DatabaseSSHHost(alias: "prod-web", hostName: "203.0.113.10", user: "deploy", port: nil),
                 DatabaseSSHHost(alias: "bastion", hostName: "bastion.example.com", user: "ops", port: 2222)]

    var p = try DatabaseURL.parse("mysql://app:s3cret@db.example.com:3307/shop")
    check(p.connection.user == "app" && p.password == "s3cret" && p.connection.host == "db.example.com")
    check(p.connection.port == 3307 && p.connection.database == "shop" && p.connection.ssh.isEmpty)

    // Raw, unencoded / : @ in the password; percent-encoded too.
    p = try DatabaseURL.parse("mysql://app:p@ss:w/rd@127.0.0.1/shop")
    check(p.connection.user == "app" && p.password == "p@ss:w/rd" && p.connection.port == 3306 && p.connection.database == "shop", "\(p)")
    p = try DatabaseURL.parse("mysql://app:p%40ss%3Aw%2Frd@127.0.0.1:3306")
    check(p.password == "p@ss:w/rd" && p.connection.database.isEmpty)

    // .env lines, quotes, jdbc and mariadb.
    p = try DatabaseURL.parse("DATABASE_URL=\"mysql://root@localhost/app_dev\"")
    check(p.connection.user == "root" && p.password == nil && p.connection.host == "localhost" && p.connection.database == "app_dev")
    p = try DatabaseURL.parse("jdbc:mysql://u:x@h:3306/d?useSSL=true")
    check(p.connection.ssl && p.connection.user == "u")
    p = try DatabaseURL.parse("mariadb://u@[::1]:3310/d")
    check(p.connection.host == "::1" && p.connection.port == 3310)

    // Query options.
    p = try DatabaseURL.parse("mysql://u:x@127.0.0.1/d?ssh=prod-web&name=Prod%20Shop&env=prod&readonly=1&sslmode=REQUIRED&statusColor=CC0000")
    check(p.connection.ssh == "prod-web" && p.connection.name == "Prod Shop" && p.connection.environment == "production")
    check(p.connection.readOnly && p.connection.ssl && p.connection.color == "#cc0000")

    // TablePlus mysql+ssh: matches a known host when it can.
    p = try DatabaseURL.parse("mysql+ssh://deploy@203.0.113.10/app:pw@127.0.0.1:3306/shop?name=Shop&statusColor=007F3D&env=staging", sshHosts: hosts)
    check(p.connection.ssh == "prod-web" && p.connection.user == "app" && p.password == "pw" && p.connection.host == "127.0.0.1", p.connection.ssh)
    check(p.connection.environment == "staging" && p.connection.name == "Shop")
    p = try DatabaseURL.parse("mysql+ssh://ops@bastion.example.com:2222/app@10.0.0.5/shop", sshHosts: hosts)
    check(p.connection.ssh == "bastion" && p.connection.host == "10.0.0.5", p.connection.ssh)
    p = try DatabaseURL.parse("mysql+ssh://me@new.example.com:2200/app@127.0.0.1/shop", sshHosts: hosts)
    check(p.connection.ssh == "me@new.example.com:2200", p.connection.ssh)
    p = try DatabaseURL.parse("mysql://app@127.0.0.1/shop?ssh=me@other.example.com", sshHosts: hosts)
    check(p.connection.ssh == "me@other.example.com", p.connection.ssh)

    // Rejections.
    for bad in ["postgres://u@h/d", "not a url", "mysql://u@h:99999/d", "mysql://u@-oProxyCommand=x/d", "mysql://u@h/d?ssh=-oProxyCommand=evil"] {
      check((try? DatabaseURL.parse(bad)) == nil, bad)
    }
    check(DatabaseURL.looksLikeURL("  mysql://x@y/z") && !DatabaseURL.looksLikeURL("hello"))

    // Round trip.
    var c = DatabaseConnection()
    c.user = "app"; c.host = "db.internal"; c.port = 3307; c.database = "my shop"; c.ssh = "prod-web"
    c.ssl = true; c.readOnly = true; c.environment = "production"; c.name = "Prod & Co"; c.color = "#cc0000"
    let url = DatabaseURL.format(c, password: "p@ss/w:rd?")
    let back = try DatabaseURL.parse(url, sshHosts: hosts)
    check(back.password == "p@ss/w:rd?", url)
    var expected = c; expected.id = back.connection.id
    check(back.connection == expected, url)
    check(!DatabaseURL.format(c).contains("p@ss"))

    // SSH destinations for the tunnel command line.
    check(DatabaseURL.sshDestination("prod-web")! == (nil, "prod-web", nil))
    check(DatabaseURL.sshDestination("me@h.example.com:2200")! == ("me", "h.example.com", 2200))
    for bad in ["-oProxyCommand=x", "a b", "@host", "me@-x", ""] { check(DatabaseURL.sshDestination(bad) == nil, bad) }

    // Validation.
    c = DatabaseConnection(); c.user = "u"
    check(c.problem == nil)
    c.database = "x;drop"; check(c.problem != nil)
    c.database = ""; c.host = "-oops"; check(c.problem != nil)

    // Stored JSON missing newer keys still decodes.
    let old = try JSONDecoder().decode(DatabaseConnection.self, from: Data(#"{"id":"1","user":"u"}"#.utf8))
    check(old.port == 3306 && old.host == "127.0.0.1" && !old.readOnly)

    print("PASS: \(count) database URL checks.")
  }
}
