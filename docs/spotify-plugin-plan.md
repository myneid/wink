# Bundled Spotify plugin: feasibility and proposed architecture

Requested: a bundled example available to Wink users, custom terminal-style UI,
Spotify login/library/search/playback and cover art. No Spotify implementation
has been added yet; the integration route needs a product decision.

## Findings (2026-11-22)

Official sources:
- https://developer.spotify.com/documentation/web-api/concepts/quota-modes
- https://developer.spotify.com/documentation/web-playback-sdk
- https://developer.spotify.com/documentation/web-playback-sdk/reference
- https://developer.spotify.com/documentation/web-api/concepts/redirect_uri
- https://developer.spotify.com/blog/2026-07-23-web-api-quota-updates

Development-mode Spotify apps allow up to five authorized users and require
the owner to have Premium. Extended-quota approval is a separate Spotify
process, not something Wink code can grant. The July update increases client
ID count to25, not the users-per-app limit. SDK streaming requires Premium;
Safari support does not prove WKWebView/custom-origin playback support.

The installed Spotify.app publishes a scripting dictionary with now-playing
metadata/artwork URL, playback controls, seek, volume, shuffle/repeat and
play-track URI. It does not offer a full library/search/playlist CRUD API.
Reading this dictionary did not control playback or trigger automation access.

## Option A: broadly distributable macOS companion

Bundle a web-plugin package with a keyboard-first terminal-style UI and artwork.
Implement narrow permission-gated `music.spotify.*` bridge methods using native
Spotify automation (explicit permission consent, no arbitrary AppleScript from
plugins). Users install/log into Spotify's own application; it handles accounts,
DRM and audio. First version: current track/artwork, play/pause, next/previous,
seek, volume, shuffle/repeat, play a pasted Spotify URI, open Spotify for browsing.
No claim of in-plugin login/search/library/playlist editing. Desktop-only backend;
future Blink host would need another backend and capability detection.

## Option B: full API client (external prerequisites)

Registered OAuth client, browser-based PKCE login, exact registered redirect,
state validation, Keychain refresh-token custody and narrow authenticated API
bridge. Library/search/playlists/queue/devices subject to current API access.
Use supported Spotify devices for audio first; separately prove streaming in
WKWebView before promising it. A public shared-client rollout needs Spotify
approval. BYO developer client IDs are a setup-heavy personal/test option,
not an everybody-can-log-in product.

## UI versus true TUI

The current extension runtime is HTML/CSS/JavaScript, not a PTY. A terminal-style
web UI can display artwork directly and remain portable. A genuine TUI emitting
Kitty graphics requires the separate terminal/process plugin backend; it should
not be described as an existing capability of the web-plugin SDK.

## Implemented follow-up

User selected the bundled OAuth route. Implementation now lives in
`Sources/SpotifyService.swift` and `Resources/Plugins/org.blink.spotify`.
See `docs/plugins.md` for current setup, capability boundary and limitations.
The earlier "no implementation" paragraph above describes the planning stage.
Wink’s registered public client ID is now bundled with the plugin; the loopback redirect is registered. Real-account end-to-end login/playback verification remains outstanding.
