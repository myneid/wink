import Foundation
@main struct SpotifyChecks {
  static func main() {
    var count = 0
    func check(_ value: Bool) { precondition(value); count += 1 }
    check(SpotifyCallback.validate("/callback?state=secret&code=abc", state: "secret").code == "abc")
    for target in ["/callback?state=wrong&code=abc", "/callback?code=abc", "/callback?state=secret&state=wrong&code=a", "/callback?state=secret&code=a&code=b", "/other?state=secret&code=a", "//evil.test/callback?state=secret&code=a"] {
      check(!SpotifyCallback.validate(target, state: "secret").valid)
    }
    check(SpotifyCallback.validate("/callback?state=secret&error=access_denied", state: "secret").valid)
    check(SpotifyCallback.validate("/callback?state=secret&error=access_denied", state: "secret").code == nil)
    for path in ["/me/player", "/me/player/devices", "/search", "/me/tracks", "/me/playlists", "/playlists/abc123/items", "/artists/abc123/albums", "/albums/abc123/tracks"] { check(SpotifyService.allowed(path: path, verb: "GET")) }
    for path in ["https://evil.test/", "//evil.test", "/me/../secrets", "/me/player?x=y", "/playlists/../items", "/me/following", "/artists/../albums", "/albums/abc/tracks?x=y", "/artists/abc/top-tracks"] { check(!SpotifyService.allowed(path: path, verb: "GET")) }
    check(!SpotifyService.allowed(path: "/artists/abc/albums", verb: "PUT"))
    check(!SpotifyService.allowed(path: "/me/tracks", verb: "DELETE"))
    check(!SpotifyService.allowed(path: "/me/player/play", verb: "GET"))
    check(SpotifyService.allowed(path: "/me/player/play", verb: "PUT"))
    check(SpotifyService.allowed(path: "/me/player/queue", verb: "POST"))
    print("PASS: \(count) Spotify OAuth callback and endpoint boundary checks")
  }
}
