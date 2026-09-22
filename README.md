# Wink

A slim local terminal for macOS in the spirit of [Blink Shell](https://github.com/blinksh/blink):
[hterm](https://chromium.googlesource.com/apps/libapps/+/HEAD/hterm) in a WKWebView,
a real PTY running your login shell, and native macOS tabs. It reads your Blink
hosts, keys and theme and turns them into a Hosts menu.

About 1,000 lines of Swift and JS. No dependencies beyond the Xcode command-line tools.

## Download

Grab `Wink-x.y.z.dmg` from [Releases](https://github.com/myneid/wink/releases), open it, and
drag Wink to Applications. It's a universal build for Apple Silicon and Intel and needs macOS 13+.

The app is ad-hoc signed and not notarized, so macOS blocks the first launch.
Right-click Wink.app and choose **Open**, or allow it under System Settings ▸
Privacy & Security ▸ **Open Anyway**. You can also run:

```bash
xattr -dr com.apple.quarantine /Applications/Wink.app
```

## Build

```bash
./build.sh            # -> build/Wink.app
./build.sh --install  # also copies it to /Applications
./make-dmg.sh         # -> build/Wink-<version>.dmg
```

## Use

| | |
|---|---|
| ⌘T / ⌘N / ⌘W | new tab / new window / close tab |
| ⌘1…⌘9, ⌘⇧[ ⌘⇧] | switch tabs |
| ⌘C / ⌘V, ⌘K | copy / paste, clear scrollback |
| ⌘+ / ⌘- / ⌘0 | font size |
| View ▸ Theme | Blink's bundled themes, your Blink custom themes, and `~/.config/wink/themes/*.js` |
| View ▸ Use Option as Meta | ⌥ sends ESC-prefixed keys (for emacs, readline ⌥B/⌥F) |
| Hosts ▸ *host* | `ssh` to it in a new tab; hold ⌥ to use `mosh` with Blink's mosh settings |

## Blink config

Blink keeps its config in its App Group container
(`~/Library/Group Containers/group.Com.CarlosCabanero.BlinkShell/home/.blink`).
macOS blocks other apps from reading it, so on first launch Wink offers two options:

- **Import…**: pick the `.blink` folder once. Wink copies `hosts`, `keys`,
  `defaults` and `Themes` to `~/.config/wink/blink-snapshot`. Use
  **Hosts ▸ Import Blink Config…** again after you change hosts in Blink.
- **Full Disk Access**: add Wink under System Settings ▸ Privacy & Security ▸
  Full Disk Access to read Blink's config live. (The build is ad-hoc signed, so
  macOS may need you to grant access again after a rebuild.)

You can also point Wink at any copy of `.blink`:
`defaults write sh.wink.Wink BlinkConfigPath /path/to/.blink`.

From that, Wink generates:

- `~/.config/wink/blink_hosts.conf`: one `Host` block per Blink host (HostName,
  User, Port, IdentityFile, ProxyJump/ProxyCommand, agent forwarding, and the
  host's raw "SSH Config" lines).
- `~/.config/wink/ssh_config`: what the Hosts menu passes to `ssh -F`. It
  includes the file above, then your `~/.ssh/config`.
- `~/.config/wink/keys/<name>.pub`: your Blink public keys.

To make plain `ssh <host>` work in any terminal, add this to the top of
`~/.ssh/config`:

```
Include ~/.config/wink/blink_hosts.conf
```

### Keys

Blink stores **private keys** (and passwords) in its own keychain group, which
no other app can read. For each host's key, Wink uses the first of these:

1. `~/.config/wink/keys/<name>`: a private key you exported from Blink
   (Settings ▸ Keys ▸ *key* ▸ Copy Private Key) and saved here with `chmod 600`.
2. `~/.ssh/<name>`, but only if its `.pub` matches Blink's key of that name.
3. `~/.config/wink/keys/<name>.pub`: ssh then uses the matching key from your
   ssh-agent (for example 1Password's or Secretive's agent).

Secure Enclave and hardware (FIDO) keys created inside Blink can't be used
outside Blink.

## Layout

- `Sources/pty.c`: `forkpty` + exec, window-size ioctl
- `Sources/TerminalWindowController.swift`: one tab = one PTY + one WKWebView, with output batching and backpressure
- `Sources/BlinkConfig.swift`: reads Blink's NSKeyedArchiver files and writes the ssh config
- `Sources/main.swift`: menus, tabs, Hosts menu
- `Resources/wink.js`: the hterm ↔ native bridge

## License

GPL-3.0 (see `LICENSE`), because it bundles Blink Shell's GPLv3 themes.
hterm is BSD-licensed (`LICENSE.hterm`, from Chromium libapps 1.70).
Wink isn't affiliated with Blink Shell.
