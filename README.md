# Wink

A slim local terminal for macOS in the spirit of [Blink Shell](https://github.com/blinksh/blink):
[hterm](https://chromium.googlesource.com/apps/libapps/+/HEAD/hterm) in a WKWebView,
a real PTY running your login shell, and native macOS tabs. It reads your Blink
hosts, keys and theme and turns them into a Hosts menu.

About 1,700 lines of Swift and JS. No dependencies beyond the Xcode command-line tools.

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
| Hosts ▸ *host* | `ssh` to it in a new tab; hold ⌥ to use `mosh` (with Blink's mosh settings for Blink hosts) |
| Hosts ▸ Edit ~/.ssh/config (⌘⇧E) | opens it in `$EDITOR` in a new tab |

## Hosts

The Hosts menu lists two groups:

- **Blink**: hosts from your Blink config (see below).
- **~/.ssh/config**: every concrete `Host` in your own config, including files it `Include`s.

To add or change hosts locally, edit `~/.ssh/config` (**Hosts ▸ Edit ~/.ssh/config**).
Your local settings override Blink's: to change a Blink host, add a `Host` block
with the same name to `~/.ssh/config`.

## Blink config (Blink → Wink)

Blink keeps its config in its App Group container
(`~/Library/Group Containers/group.Com.CarlosCabanero.BlinkShell/home/.blink`).
macOS blocks other apps from reading it, so on first launch Wink offers two options:

- **Import…**: pick the `.blink` folder once. Wink copies `hosts`, `keys`,
  `defaults` and `Themes` to `~/.config/wink/blink-snapshot`. Use
  **Hosts ▸ Blink ▸ Import Blink Config…** again after you change hosts in Blink.
- **Full Disk Access**: add Wink under System Settings ▸ Privacy & Security ▸
  Full Disk Access to read Blink's config live. (Until the app is Developer ID
  signed, macOS may need you to grant access again after a rebuild.)

You can also point Wink at any copy of `.blink`:
`defaults write sh.wink.Wink BlinkConfigPath /path/to/.blink`.

From that, Wink generates:

- `~/.config/wink/blink_hosts.conf`: one `Host` block per Blink host (HostName,
  User, Port, IdentityFile, ProxyJump/ProxyCommand, agent forwarding, and the
  host's raw "SSH Config" lines).
- `~/.config/wink/ssh_config`: what the Hosts menu passes to `ssh -F`. It
  includes your `~/.ssh/config` first, then Blink's hosts.
- `~/.config/wink/keys/<name>.pub`: your Blink public keys.

To make plain `ssh <blink-host>` work in any terminal, add this to the **end** of
`~/.ssh/config`:

```
Match all
  Include ~/.config/wink/blink_hosts.conf
```

### Blink's keys

Blink keeps private keys in its own keychain group, which no other app can
read. Blink doesn't sync them between devices either. To use one in Wink:

1. In Blink: Settings ▸ Keys ▸ *key* ▸ **Copy Private Key**.
2. In Wink: **Hosts ▸ Blink ▸ Save Private Key from Clipboard…**, using the
   key's Blink name. Wink saves it as `~/.config/wink/keys/<name>` (mode 600),
   checks it against Blink's public key, and clears the clipboard.

Without that, Wink uses `~/.ssh/<name>` if it's the same key, or else the exported
`.pub`, so ssh can use a matching key loaded in your ssh-agent (for example
1Password or Secretive).

## Sharing your ~/.ssh/config with Blink (Wink → Blink)

Blink's host database syncs through a private iCloud store that other apps can't
reach, so Wink can't add hosts to Blink's host list. It can do the next best
thing: Blink reads a standard `~/.ssh/config` inside its own home folder, and
that file can `Include` a file from Blink's iCloud Drive folder, which Wink can write.

1. Turn on **Hosts ▸ Blink ▸ Share ~/.ssh/config with Blink**. Wink writes a
   Blink-safe copy to Blink's iCloud Drive (`~/iCloud/wink/ssh_config` inside
   Blink) and keeps it updated while Wink runs.
2. Once per device, run these in a Blink shell (**Copy Blink Setup Command** puts
   them on the clipboard):

   ```
   echo 'Host *' >> ~/.ssh/config
   echo '  Include ../iCloud/wink/ssh_config' >> ~/.ssh/config
   ```

   The `Host *` line is required: Blink attaches an `Include` to the `Host`
   block it sits in. Hosts you define in Blink's UI keep priority.
3. For each key those hosts use, choose **Hosts ▸ Blink ▸ Copy Private Key for
   Blink ▸ *name***, then in Blink: Settings ▸ Keys ▸ + ▸ **Import from
   Clipboard**, with the same name. Universal Clipboard carries it to an iPad.
   Wink marks the clipboard entry as concealed and clears it after 90 seconds.

The copy is adapted for Blink's parser, which rejects the whole config on
anything it doesn't support:

- `Include`s are inlined.
- `Match` blocks and Mac-only options (`IdentityAgent`, `UseKeychain`,
  `ControlPath`, ...) are dropped, as are values Blink rejects.
- `IdentityFile ~/.ssh/id_work` becomes the Blink key name `id_work`.

On iPad, iCloud may not download the shared file until something opens it. If
hosts are missing, open Blink's folder in the Files app once.

## Layout

- `Sources/pty.c`: `forkpty` + exec, window-size ioctl
- `Sources/TerminalWindowController.swift`: one tab = one PTY + one WKWebView, with output batching and backpressure
- `Sources/BlinkConfig.swift`: reads Blink's NSKeyedArchiver files and writes the ssh config
- `Sources/LocalSSHConfig.swift`: reads `~/.ssh/config` and writes the Blink-safe copy
- `Sources/HostsMenu.swift`: the Hosts menu and the Blink key and config actions
- `Sources/main.swift`: menus, tabs, Hosts menu
- `Resources/wink.js`: the hterm ↔ native bridge

## License

GPL-3.0 (see `LICENSE`), because it bundles Blink Shell's GPLv3 themes.
hterm is BSD-licensed (`LICENSE.hterm`, from Chromium libapps 1.70).
Wink isn't affiliated with Blink Shell.
