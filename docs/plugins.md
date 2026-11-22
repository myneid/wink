# Portable web plugins — API 1 (experimental)

Wink implements the first host. Blink/iOS is **not implemented or tested**.
The package, JavaScript contract and capability names are platform-neutral:
a future Blink host should load the same package without changes to its code.
Do not branch on host name when capability detection suffices.

## Try it

Build Wink and choose **Apps → Plugin Playground**. Each plugin has its own
tab in the current Wink window (one instance per ID). Reopening an app selects
its existing tab. If no Wink window exists, a new window is created. **Apps → Open Apps Folder…** reveals
`~/Library/Application Support/Wink/Plugins/`. Copy a package directory there;
the menu rescans when opened. No restart, registry or install script is needed.
Bundled IDs take precedence; duplicate user IDs are ignored. Invalid packages
appear disabled with the validation reason in their tooltip.

## Install from GitHub

Choose **Apps → Install from GitHub…** and paste either:

- `https://github.com/owner/plugin` (manifest at repository root; default branch)
- `https://github.com/owner/repo/tree/main/path/to/plugin` (manifest in that folder)
- `https://github.com/owner/repo/tree/<40-character-commit>/path/to/plugin`

Choose **Download for Review** to contact GitHub, then review the app name,
version, ID, repository, pinned commit and permissions. **Install** moves the
validated snapshot into the Apps folder and opens it. Cancel leaves it
uninstalled. Downloads are staged in Wink's `PluginDownloads` sibling folder;
cancelled/failed staging files are retained, not shown in the Apps menu.

Public repositories only; no GitHub login, Git executable, package manager,
submodule, build script or remote code execution during installation. Publish
ready-to-run HTML/JS/CSS assets alongside `manifest.json`. Files are pinned to
one commit even if the branch moves during download. Branch names containing
slashes require a commit-SHA link (tree URLs otherwise treat the first segment
after `tree` as the reference). Link folder names use letters, digits, dots,
underscores or hyphens. Private repositories and GitHub release ZIP links are
not supported in this version.

The installer rejects symlinks/submodules, traversal, incomplete repository
trees, over 256 files, files over 8 MiB, packages over 32 MiB and invalid
manifests. An existing or bundled plugin ID cannot be replaced. There are no
automatic updates yet. Installed packages record repository/path/commit/time
in a host-written `.wink-source.json`; packages cannot supply that filename.
This receipt is provenance, not proof of publisher identity or code safety.
GitHub requests use an ephemeral unauthenticated session; rate limits apply.
The plugin itself still has **no network capability** after installation.

## Package contract

```
org.example.myapp/
  manifest.json
  index.html
  app.js
  style.css
```

```json
{
  "manifestVersion": 1,
  "id": "org.example.myapp",
  "name": "My App",
  "version": "1.0.0",
  "entry": "index.html",
  "permissions": ["storage"]
}
```

IDs are lowercase reverse-domain identifiers (letters, digits and hyphens in
segments; first segment starts with a letter). Entry must be a relative `.html`
file inside the package. Symlinks resolving outside the package, parent traversal,
unknown permissions and unsupported manifest versions are rejected. Manifest
limit: 64 KiB; individual asset limit: 8 MiB. Use separate script/style files:
inline scripts, inline styles, eval and remote assets are intentionally blocked.
Asset paths are case sensitive; use relative URLs, not host-specific paths.

## JavaScript contract

`window.blink` is available before the entry document runs. Methods return
Promises and reject with an error on unsupported operations, invalid arguments
or missing permissions. No SDK dependency or build system is required.

```js
const info = await blink.host.info();
// {apiVersion: 1, host: 'wink', platform: 'macos', pluginID: '...',
//  capabilities: ['host.info', 'storage.get', 'storage.set']}
if (info.capabilities.includes('storage.set')) {
  await blink.storage.set('note', 'hello');
  const note = await blink.storage.get('note');
}
```

- `blink.apiVersion`: 1.
- `blink.host.info()`: always available, no permission required.
- `blink.storage.get(key)`: string or null when missing; requires `storage`.
- `blink.storage.set(key, value)`: resolves true; string values only, requires
  `storage`. Keys: 1–256 UTF-8 bytes. Aggregate serialized quota: 64 KiB/plugin.
  Use JSON.stringify/parse for structured values. Data persists across windows
  and launches in native UserDefaults, namespaced by manifest ID; no cloud sync.

Storage is not a secrets vault. Packages claiming the same ID share its stored
data; there is no publisher identity/signature verification in this local-only
prototype. Install trusted packages only. Permission declarations are validated
and enforced, not an interactive approval/publisher trust system.

## Isolation and limits

Each window uses a fresh nonpersistent WebKit data store and a custom
`blink-plugin://<id>/` resource handler limited to that package's regular files.
The host applies CSP to served documents: no network connections, remote
resources, frames, media, forms or object embedding. Navigation outside that
plugin origin is cancelled. Native bridge messages must come from the main
frame and its plugin origin. It exposes no shell, PTY, SSH state, arbitrary
filesystem access, clipboard or native music controls.

Thus v1 is **not yet a Spotify/Apple Music player**. Those need separately
specified, capability-detected native services plus an authentication and
permission design. Network capability, background audio, plugin signatures,
marketplace, lifecycle events and iOS/App Store distribution are
future work, not promises made by this implementation. This is a web-app
extension host, not a runtime for native TUI binaries.

## Verification

`tools/check-plugins.sh` runs package boundary checks, offline GitHub installer fixtures, plus a real macOS
WKWebView loading the example, querying the host, saving a note, and closing.
It needs a logged-in macOS GUI session. Fixtures and binaries are retained in
/tmp. Full Swift type-check:

```
swiftc -typecheck -swift-version 5 -import-objc-header Sources/pty.h Sources/*.swift
```

## Bundled Spotify example (experimental)

**Apps → Spotify** opens a keyboard-driven Spotify Connect companion. This is a
web plugin with directly rendered artwork, not a PTY or Kitty-graphics backend.
It provides OAuth login, track search, liked songs, playlist browsing, queue
browsing/addition, device transfer, play/pause, skipping, seek, volume,
shuffle and repeat. Audio plays on an existing Spotify device. Playlist editing,
library mutation, podcasts and in-WebView streaming are not implemented.

The bundled plugin includes Wink’s public Spotify client ID; users click
**Connect with Spotify** without registering their own app. Its registered redirect
URI is `http://127.0.0.1:43821/callback`. No client secret is used (PKCE).
Development-app user restrictions still apply; bundling does not confer public Spotify access. API availability
and Premium requirements depend on Spotify's current access policy.

The host opens browser OAuth authorization-code flow with S256 PKCE and random
state. A loopback-only listener runs for up to three minutes on port 43821;
closing the plugin cancels login. Credentials and refresh tokens live in macOS
Keychain. Plugin JavaScript cannot read them. Disconnect removes local tokens;
it does not revoke consent on Spotify's website. Only explicitly allowlisted
API routes are exposed. Artwork is fetched from Spotify's artwork host and
returned as data, keeping the plugin's default no-network CSP intact.

`spotify` is a reserved permission. The host grants it only to the actual
bundled `org.blink.spotify` package path and ID, not to downloaded packages
claiming that ID or permission. This is a privileged bundled-example service,
not a general OAuth/network permission for third-party extensions. Future
publisher identity/consent design is required before opening it more broadly.

Portable JS contract (capability-detect `spotify` via `blink.host.info()`):

- `blink.spotify.status()` → `{connected, redirectURI}` (stored credential
  presence, not proof that Spotify currently accepts those credentials).
- `blink.spotify.login(clientID)` → true; browser PKCE login.
- `blink.spotify.logout()` → true; clear credentials.
- `blink.spotify.request(verb, path, query, body?)` → API JSON or null.
  Paths are relative to `/v1`, exact-allowlisted, and never arbitrary URLs.
- `blink.spotify.artwork(url)` → bounded image data URL from `i.scdn.co`.

Blink/iOS does not yet implement this service. Its callback/authentication and
secure-storage backend will differ; the plugin-facing API need not change.

Reference: [Spotify PKCE](https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow)
and [redirect requirements](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri).
