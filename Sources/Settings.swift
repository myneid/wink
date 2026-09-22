import Foundation

// Appearance settings. Until you change something in Wink, it follows Blink's
// theme and font size.
final class Settings {
  static let shared = Settings()
  private let d = UserDefaults.standard

  static let defaultFontFamily = "ui-monospace, Menlo, monospace"

  var fontSize: Int {
    get {
      let v = d.integer(forKey: "fontSize")
      return v > 0 ? v : (BlinkConfig.shared.appearance.fontSize ?? 14)
    }
    set { d.set(min(max(newValue, 8), 48), forKey: "fontSize") }
  }

  /// CSS font-family. Uses Blink's font name first when it's set, falling back
  /// to the system monospace font if that font isn't installed on this Mac.
  var fontFamily: String {
    if let custom = d.string(forKey: "fontFamily") { return custom }
    if let blink = BlinkConfig.shared.appearance.fontName, !blink.isEmpty {
      return "\"\(blink)\", " + Self.defaultFontFamily
    }
    return Self.defaultFontFamily
  }

  var optionIsMeta: Bool {
    get { d.bool(forKey: "optionIsMeta") }
    set { d.set(newValue, forKey: "optionIsMeta") }
  }

  var themeName: String {
    get {
      if let name = d.string(forKey: "theme"), themes[name] != nil { return name }
      if let blink = BlinkConfig.shared.appearance.themeName, themes[blink] != nil { return blink }
      return "Default"
    }
    set { d.set(newValue, forKey: "theme") }
  }

  var themeSource: String {
    guard let url = themes[themeName] else { return "" }
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
  }

  /// Bundled Blink themes, then Blink's custom themes, then ~/.config/wink/themes.
  var themes: [String: URL] {
    var out: [String: URL] = [:]
    let dirs = [
      Bundle.main.resourceURL!.appendingPathComponent("Themes"),
      BlinkConfig.winkDir.appendingPathComponent("themes"),
    ]
    for dir in dirs {
      for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
      where url.pathExtension == "js" {
        out[url.deletingPathExtension().lastPathComponent] = url
      }
      if dir == dirs[0] {
        out.merge(BlinkConfig.shared.customThemes) { _, blink in blink }
      }
    }
    return out
  }
}
