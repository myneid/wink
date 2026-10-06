<p align="center"><img src="assets/wink-icon.png" width="160" alt="Wink icon: a semicolon wink in a teal ring"></p>

# Wink

A slim local terminal for macOS in the spirit of [Blink Shell](https://github.com/blinksh/blink):
[hterm](https://chromium.googlesource.com/apps/libapps/+/HEAD/hterm) in a WKWebView,
a real PTY running your login shell, and native macOS tabs.

- **Blink hosts and keys:** a Hosts menu built from your Blink config and your
  `~/.ssh/config`, with `ssh` or `mosh` in a new tab, plus sharing your ssh
  config and keys back to Blink.
- **Images:** kitty's graphics protocol, including inside tmux.
- **Links and mouse:** ⌘-click URLs to open them, and mouse wheel and clicks
  work in tmux, vim, htop and other mouse-aware programs.
- **tmux:** **Window ▸ Fit Window to tmux** sizes the window to a tmux
  session that a smaller client (such as an iPad) is also attached to, and
  images and the mouse work inside tmux.
- **Themes:** Blink's themes and fonts.

About 2,900 lines of Swift and JS. No dependencies beyond the Xcode command-line tools.

## Download

Grab `Wink-x.y.z.dmg` from [Releases](https://github.com/myneid/wink/releases), open it, and
drag Wink to Applications. It's a universal build for Apple Silicon and Intel and needs macOS 13+.

It's signed with a Developer ID and notarized by Apple, so it opens normally.

## Build

```bash
./build.sh            # -> build/Wink.app
./build.sh --install  # also copies it to /Applications
./make-dmg.sh         # -> build/Wink-<version>.dmg
```

`make-dmg.sh` signs with the first "Developer ID Application" certificate in
your keychain, notarizes through the Apple account signed in to Xcode (or a
`notarytool` keychain profile named `wink-notary`), and staples the ticket.
Without a certificate, it builds an ad-hoc signed DMG.

## Use

| | |
|---|---|
| ⌘T / ⌘N / ⌘W | new tab / new window / close tab |
| ⌘1…⌘9, ⌘⇧[ ⌘⇧] | switch tabs |
| Window ▸ Fit Window to tmux (⌥⌘T) | resizes the window to exactly fit the tmux window in this tab (see [tmux window size](#tmux-window-size)) |
| ⌘C / ⌘V, ⌘K | copy / paste, clear scrollback |
| hold ⌘ over a URL, ⌘-click | underlines it; opens it in your browser (see [Links](#links)) |
| ⌘+ / ⌘- / ⌘0 | font size |
| View ▸ Theme | Blink's bundled themes, your Blink custom themes, and `~/.config/wink/themes/*.js` |
| View ▸ Use Option as Meta | ⌥ sends ESC-prefixed keys (for emacs, readline ⌥B/⌥F) |
| Hosts ▸ *host* | `ssh` to it in a new tab; hold ⌥ to use `mosh` (with Blink's mosh settings for Blink hosts) |
| Hosts ▸ Edit ~/.ssh/config (⌘⇧E) | opens it in `$EDITOR` in a new tab |

## Links

Hold ⌘ to underline the URL under the pointer, and ⌘-click to open it in
your default browser. Wink recognizes `http(s)://`, `ftp://`, `file://`,
`mailto:` and bare `www.` links, including URLs that wrap onto the next line.
Trailing punctuation isn't included (`…/wink.` opens without the period), and
parentheses that belong to the link are kept (`wiki/Foo_(bar)`).

This works in tmux with `mouse on` too: the ⌘-click opens the link and isn't
passed to tmux. Only web, mail, ftp and local file links are opened, so text
printed in the terminal can't launch other apps through custom URL schemes.

## Mouse

Programs that ask for mouse input get it: clicks, drags and the scroll wheel
work in tmux (`set -g mouse on`), vim (`set mouse=a`), htop, less and others.
Trackpad scrolling sends one step per line of movement, so a swipe scrolls
smoothly instead of jumping. Hold ⌥ while dragging to select text in those
programs instead of sending the drag to them.

## tmux window size

When a smaller client is attached to the same tmux session (another window,
or Blink on an iPad), tmux shrinks the session's windows to fit it, and a
bigger Wink window shows tmux with filler around it. **Window ▸ Fit Window
to tmux** (⌥⌘T) asks the tmux running in the current tab how big its window
is (plus the status line) and resizes the Wink window to fit exactly.

It works when tmux runs in the tab on this Mac, including servers started
with `-L`/`-S` or a custom `TMUX_TMPDIR`. For tmux on another machine, run
`tmux resize-window -A` there, or reattach with `tmux attach -d` to detach
the other clients.

## Images (kitty graphics protocol)

Wink shows images sent with [kitty's graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/),
so tools like `kitten icat`, yazi, timg (`-pk`), chafa (`-f kitty`), image.nvim and
viu can draw pictures right in the terminal.

- **Supported:** PNG and raw RGB/RGBA data, with or without zlib compression,
  sent inline (works over ssh) or by local file, temp file or shared memory.
  You can also place, crop, scale to cells, layer images behind or above the
  text, place images relative to each other, and delete them every way the
  protocol defines.
- **Behavior:** images scroll with the text and are cleared by `clear`. Images
  on the main screen are hidden while vim or less use the alternate screen,
  and come back when you return.
- **Reporting sizes:** Wink reports the window and cell sizes in pixels
  (`TIOCGWINSZ`, `CSI 14/16/18 t`), so tools size their images correctly.
- **Not supported:** animation.

To try it, use the `wink-icat` script in this repo (no dependencies; converts
JPEG, HEIC, GIF and other formats with macOS's `sips`):

```bash
tools/wink-icat some.png
tools/wink-icat --cols 40 photo.jpg
```

or any kitty-protocol tool, such as `chafa -f kitty some.png` or `kitten icat some.png`.

### Images inside tmux

tmux needs two settings in `~/.tmux.conf` for images to work inside it:

```
set -g allow-passthrough on
set -as terminal-features ',xterm*:RGB'
```

The first lets image data through tmux. The second keeps true colors intact:
tools that draw images in tmux use Unicode placeholder characters, and the
image id is carried in the text color.

The program also has to support tmux. Inside tmux it must wrap the image data
in tmux's passthrough escape and display it with placeholder characters;
images drawn the plain way are dropped by tmux or painted over when it
redraws. `wink-icat`, yazi, image.nvim and `kitten icat` do this. Simple
scripts that print the escape codes directly, such as the example
`send-png` script in kitty's protocol docs, work only outside tmux.

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
  Full Disk Access to read Blink's config live. Release builds are Developer ID
  signed, so the permission carries over when you update. Builds you make
  yourself with `./build.sh` are ad-hoc signed and may need it granted again.

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

- `Sources/main.swift`: app setup, menus and tabs
- `Sources/TerminalWindowController.swift`: one tab = one PTY + one WKWebView, with output batching and backpressure
- `Sources/pty.c`: `forkpty` + exec, window size in cells and pixels, shared-memory helper
- `Sources/HostsMenu.swift`: the Hosts menu and the Blink key and config actions
- `Sources/BlinkConfig.swift`: reads Blink's NSKeyedArchiver files and writes the ssh config
- `Sources/LocalSSHConfig.swift`: reads `~/.ssh/config` and writes the Blink-safe copy
- `Sources/ImageFiles.swift`: reads image files and shared memory for the graphics protocol
- `Sources/TmuxSize.swift`: asks the tmux in a tab for its window size (Fit Window to tmux)
- `Sources/Settings.swift`: font, theme and option settings
- `Resources/wink.js`: the hterm ↔ native bridge, links, mouse-wheel and size reporting
- `Resources/kitty.js`: the kitty graphics protocol (images, placements, Unicode placeholders)
- `tools/wink-icat`: shows an image with the kitty protocol, in or out of tmux

## License

GPL-3.0 (see `LICENSE`), because it bundles Blink Shell's GPLv3 themes.
hterm is BSD-licensed (`LICENSE.hterm`, from Chromium libapps 1.70).
Wink isn't affiliated with Blink Shell.
