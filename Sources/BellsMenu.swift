import AppKit

// The Bells menu: BLINK_BELL values pasted from Blink, which host each one is
// for, and which is the default. See Bells.swift.
final class BellsMenuController: NSObject, NSMenuDelegate {
  let menu = NSMenu(title: "Bells")
  private var store: BellStore { .shared }

  override init() {
    super.init()
    menu.delegate = self
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    if store.bells.isEmpty {
      menu.addItem(withTitle: "No bells yet", action: nil, keyEquivalent: "").isEnabled = false
    }
    for bell in store.bells {
      var title = bell.name
      if bell.isDefault { title += "  (default)" }
      if !bell.hosts.isEmpty { title += "  · " + bell.hosts.joined(separator: ", ") }
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      item.submenu = submenu(for: bell)
      menu.addItem(item)
    }
    menu.addItem(.separator())
    add("Add Bell from Clipboard…", #selector(addFromClipboard(_:)), to: menu)
    add("About Bells", #selector(openHelp(_:)), to: menu)
  }

  private func submenu(for bell: Bell) -> NSMenu {
    let m = NSMenu()
    let def = add("Use for Tabs Without a Host", #selector(toggleDefault(_:)), to: m, bell)
    def.state = bell.isDefault ? .on : .off
    add("Assign Hosts…", #selector(assignHosts(_:)), to: m, bell)
    m.addItem(.separator())
    add("Send Test Ring", #selector(testRing(_:)), to: m, bell)
    add("Copy BLINK_BELL Line", #selector(copyLine(_:)), to: m, bell)
    m.addItem(.separator())
    add("Remove…", #selector(remove(_:)), to: m, bell)
    return m
  }

  @discardableResult
  private func add(_ title: String, _ action: Selector, to menu: NSMenu, _ bell: Bell? = nil) -> NSMenuItem {
    let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
    item.target = self
    item.representedObject = bell.map { BellBox($0) }
    return item
  }

  private func bell(_ sender: Any?) -> Bell? {
    guard let id = ((sender as? NSMenuItem)?.representedObject as? BellBox)?.bell.id else { return nil }
    return store.bells.first { $0.id == id }
  }

  // MARK: - Actions

  @objc private func addFromClipboard(_ sender: Any?) {
    let pasteboard = NSPasteboard.general
    guard let text = pasteboard.string(forType: .string), let value = BellStore.parseValue(text) else {
      alert("No bell on the clipboard",
            "In Blink, create a bell (New bell) and copy its BLINK_BELL line, then choose Add Bell from Clipboard again.")
      return
    }
    if let existing = store.bells.first(where: { store.value(of: $0) == value }) {
      alert("Already added", "This bell is in Wink as “\(existing.name)”.")
      return
    }
    let name = field("Name, e.g. build-box")
    let hosts = field("Hosts it's for (optional): host1, host2")
    let isDefault = NSButton(checkboxWithTitle: "Use for tabs without a host", target: nil, action: nil)
    isDefault.state = store.bells.contains(where: \.isDefault) ? .off : .on
    let stack = NSStackView(views: [name, hosts, isDefault])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.frame = NSRect(x: 0, y: 0, width: 300, height: 82)

    let a = NSAlert()
    a.messageText = "Add bell"
    a.informativeText = """
      Wink puts this bell into new tabs and answers Blink's shell integration with it. \
      Rings go to the devices this bell is bound to in Blink. \
      Value: \(BellStore.token(of: value).prefix(9))…\(value.contains(".") ? " (with encryption secret)" : "")
      """
    a.accessoryView = stack
    a.addButton(withTitle: "Add")
    a.addButton(withTitle: "Cancel")
    a.window.initialFirstResponder = name
    guard a.runModal() == .alertFirstButtonReturn else { return }

    let label = name.stringValue.trimmingCharacters(in: .whitespaces)
    guard store.add(name: label.isEmpty ? "Bell \(store.bells.count + 1)" : label, value: value,
                    hosts: hostList(hosts.stringValue), isDefault: isDefault.state == .on) else {
      alert("Couldn't save the bell", "Wink couldn't store it in your Keychain.")
      return
    }
    // The line carries the bell's secret; don't leave it lying on the clipboard.
    if pasteboard.string(forType: .string) == text { pasteboard.clearContents() }
  }

  @objc private func toggleDefault(_ sender: Any?) {
    guard var bell = bell(sender) else { return }
    bell.isDefault.toggle()
    store.update(bell)
  }

  @objc private func assignHosts(_ sender: Any?) {
    guard var bell = bell(sender) else { return }
    let hosts = field("host1, host2")
    hosts.stringValue = bell.hosts.joined(separator: ", ")
    hosts.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
    let a = NSAlert()
    a.messageText = "Hosts for “\(bell.name)”"
    a.informativeText = """
      Tabs connected to these hosts get this bell: Hosts-menu tabs, and any tab where \
      ssh or mosh to the host is running. Use the names you ssh to, like the aliases in your ssh config.
      """
    a.accessoryView = hosts
    a.addButton(withTitle: "Save")
    a.addButton(withTitle: "Cancel")
    a.window.initialFirstResponder = hosts
    guard a.runModal() == .alertFirstButtonReturn else { return }
    bell.hosts = hostList(hosts.stringValue)
    store.update(bell)
  }

  @objc private func testRing(_ sender: Any?) {
    guard let bell = bell(sender) else { return }
    store.testRing(bell) { [weak self] message in
      self?.alert("Test ring: \(bell.name)", message + "\n\nRelay: \(BellStore.shared.relayURL)")
    }
  }

  @objc private func copyLine(_ sender: Any?) {
    guard let bell = bell(sender), let value = store.value(of: bell) else { return }
    let pb = NSPasteboard.general
    pb.clearContents()
    // Concealed, and cleared after 90 seconds: it carries the bell's secret.
    pb.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
    pb.setString("export BLINK_BELL='\(value)'", forType: .string)
    pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    let change = pb.changeCount
    DispatchQueue.main.asyncAfter(deadline: .now() + 90) { if pb.changeCount == change { pb.clearContents() } }
  }

  @objc private func remove(_ sender: Any?) {
    guard let bell = bell(sender) else { return }
    let a = NSAlert()
    a.messageText = "Remove “\(bell.name)” from Wink?"
    a.informativeText = "The bell itself stays in Blink. This only removes Wink's copy; new tabs stop getting it."
    a.addButton(withTitle: "Remove")
    a.addButton(withTitle: "Cancel")
    if a.runModal() == .alertFirstButtonReturn { store.remove(bell) }
  }

  @objc private func openHelp(_ sender: Any?) {
    NSWorkspace.shared.open(URL(string: "https://github.com/myneid/wink#bells-blink-bell")!)
  }

  // MARK: - helpers

  private func field(_ placeholder: String) -> NSTextField {
    let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
    f.placeholderString = placeholder
    return f
  }

  private func hostList(_ text: String) -> [String] {
    text.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty }
  }

  private func alert(_ title: String, _ text: String) {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = text
    a.runModal()
  }
}

private final class BellBox: NSObject {
  let bell: Bell
  init(_ bell: Bell) { self.bell = bell }
}
