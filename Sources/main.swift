import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
  private let hosts = HostsMenuController()
  private let themesMenu = NSMenu(title: "Theme")

  func applicationDidFinishLaunching(_ note: Notification) {
    BlinkConfig.shared.reload()
    NSApp.mainMenu = buildMainMenu()
    newWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
    hosts.didLaunch()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

  func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if !hasVisibleWindows { newWindow(nil) }
    return true
  }

  // MARK: - Terminals

  private var keyTerminal: TerminalWindowController? {
    NSApp.keyWindow?.windowController as? TerminalWindowController
      ?? NSApp.mainWindow?.windowController as? TerminalWindowController
  }

  func open(_ term: TerminalWindowController, asTab: Bool) {
    if asTab, let host = NSApp.keyWindow ?? NSApp.mainWindow, let w = term.window {
      host.addTabbedWindow(w, ordered: .above)
    }
    term.showWindow(nil)
    term.window?.makeKeyAndOrderFront(nil)
  }

  @objc func newWindow(_ sender: Any?) {
    let term = TerminalWindowController()
    // Keep a separate window even with "prefer tabs" system settings.
    term.window?.tabbingMode = .disallowed
    open(term, asTab: false)
    term.window?.tabbingMode = .preferred
  }

  // Also powers the "+" button in the tab bar.
  @objc func newWindowForTab(_ sender: Any?) {
    open(TerminalWindowController(), asTab: true)
  }

  @objc func selectTab(_ sender: NSMenuItem) {
    guard let tabs = NSApp.keyWindow?.tabbedWindows ?? NSApp.keyWindow.map({ [$0] }) else { return }
    let i = sender.tag == 9 ? tabs.count - 1 : sender.tag - 1
    if tabs.indices.contains(i) { tabs[i].makeKeyAndOrderFront(nil) }
  }

  // MARK: - Appearance

  private func broadcast(_ fn: String, _ arg: Any) {
    TerminalWindowController.all.forEach { $0.call(fn, arg) }
  }

  @objc func biggerFont(_ sender: Any?) { setFontSize(Settings.shared.fontSize + 1) }
  @objc func smallerFont(_ sender: Any?) { setFontSize(Settings.shared.fontSize - 1) }
  @objc func resetFont(_ sender: Any?) {
    UserDefaults.standard.removeObject(forKey: "fontSize")
    setFontSize(Settings.shared.fontSize)
  }
  private func setFontSize(_ size: Int) {
    Settings.shared.fontSize = size
    broadcast("wink.setFontSize", Settings.shared.fontSize)
  }

  @objc func toggleOptionIsMeta(_ sender: NSMenuItem) {
    Settings.shared.optionIsMeta.toggle()
    broadcast("wink.setOptionIsMeta", Settings.shared.optionIsMeta)
  }

  @objc func selectTheme(_ sender: NSMenuItem) {
    Settings.shared.themeName = sender.title
    broadcast("wink.applyTheme", Settings.shared.themeSource)
  }

  @objc func clearTerminal(_ sender: Any?) { keyTerminal?.call("wink.clear") }

  private func rebuildThemesMenu() {
    themesMenu.removeAllItems()
    let current = Settings.shared.themeName
    for name in Settings.shared.themes.keys.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
      let item = themesMenu.addItem(withTitle: name, action: #selector(selectTheme(_:)), keyEquivalent: "")
      item.state = name == current ? .on : .off
    }
  }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    if item.action == #selector(toggleOptionIsMeta(_:)) {
      item.state = Settings.shared.optionIsMeta ? .on : .off
    }
    return true
  }

  // MARK: - Menu bar

  private func buildMainMenu() -> NSMenu {
    let main = NSMenu()

    func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
      let m = NSMenu(title: title)
      items.forEach(m.addItem)
      let host = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      host.submenu = m
      main.addItem(host)
      return m
    }
    func item(_ title: String, _ action: Selector?, _ key: String = "",
              _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
      let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
      i.keyEquivalentModifierMask = mods
      return i
    }

    _ = submenu("Wink", [
      item("About Wink", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
      .separator(),
      item("Hide Wink", #selector(NSApplication.hide(_:)), "h"),
      item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
      item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
      .separator(),
      item("Quit Wink", #selector(NSApplication.terminate(_:)), "q"),
    ])

    _ = submenu("Shell", [
      item("New Window", #selector(newWindow(_:)), "n"),
      item("New Tab", #selector(newWindowForTab(_:)), "t"),
      .separator(),
      item("Close Tab", #selector(NSWindow.performClose(_:)), "w"),
    ])

    _ = submenu("Edit", [
      item("Copy", #selector(NSText.copy(_:)), "c"),
      item("Paste", #selector(NSText.paste(_:)), "v"),
      item("Select All", #selector(NSText.selectAll(_:)), "a"),
      .separator(),
      item("Clear Scrollback", #selector(clearTerminal(_:)), "k"),
    ])

    let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
    themeItem.submenu = themesMenu
    themesMenu.delegate = self
    _ = submenu("View", [
      item("Bigger", #selector(biggerFont(_:)), "+"),
      item("Bigger", #selector(biggerFont(_:)), "="),
      item("Smaller", #selector(smallerFont(_:)), "-"),
      item("Default Size", #selector(resetFont(_:)), "0"),
      .separator(),
      themeItem,
      item("Use Option as Meta", #selector(toggleOptionIsMeta(_:))),
      .separator(),
      item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
    ])
    // Hide the duplicate "=" item; it just makes ⌘= work without shift.
    main.items.last?.submenu?.items[1].isHidden = true
    main.items.last?.submenu?.items[1].allowsKeyEquivalentWhenHidden = true

    let hostsItem = NSMenuItem(title: "Hosts", action: nil, keyEquivalent: "")
    hostsItem.submenu = hosts.menu
    main.addItem(hostsItem)

    var windowItems: [NSMenuItem] = [
      item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
      item("Zoom", #selector(NSWindow.performZoom(_:))),
      .separator(),
      item("Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "[", [.command, .shift]),
      item("Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "]", [.command, .shift]),
      item("Move Tab to New Window", #selector(NSWindow.moveTabToNewWindow(_:))),
      item("Merge All Windows", #selector(NSWindow.mergeAllWindows(_:))),
      .separator(),
    ]
    for n in 1...9 {
      let i = item(n == 9 ? "Select Last Tab" : "Select Tab \(n)", #selector(selectTab(_:)), "\(n)")
      i.tag = n
      windowItems.append(i)
    }
    windowItems += [.separator(), item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))]
    NSApp.windowsMenu = submenu("Window", windowItems)

    return main
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
