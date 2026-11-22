# Portable web plugins — API 1 (experimental)

Wink implements the first host. Blink/iOS is **not implemented or tested**.
The package, JavaScript contract and capability names are platform-neutral:
a future Blink host should load the same package without changes to its code.
Do not branch on host name when capability detection suffices.

## Try it

Build Wink and choose **Apps → Plugin Playground**. Each plugin has its own
window (one instance per ID). **Apps → Open Apps Folder…** reveals
`~/Library/Application Support/Wink/Plugins/`. Copy a package directory there;
the menu rescans when opened. No restart, download, registry or install script.
Bundled IDs take precedence; duplicate user IDs are ignored. Invalid packages
appear disabled with the validation reason in their tooltip.

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
marketplace, import UI, lifecycle events and iOS/App Store distribution are
future work, not promises made by this implementation. This is a web-app
extension host, not a runtime for native TUI binaries.

## Verification

`tools/check-plugins.sh` runs package boundary checks plus a real macOS
WKWebView loading the example, querying the host, saving a note, and closing.
It needs a logged-in macOS GUI session. Fixtures and binaries are retained in
/tmp. Full Swift type-check:

```
swiftc -typecheck -swift-version 5 -import-objc-header Sources/pty.h Sources/*.swift
```
