import AppKit
import SidebarCore

enum ChromeError: Error, Equatable {
  /// macOS blocked the Apple Event (System Settings → Privacy & Security → Automation).
  case notAuthorized
  case notRunning
  case script(code: Int, message: String)
}

/// Talks to Chrome through AppleScript. Runs on the main thread: each call is a
/// few milliseconds, and the sidebar only polls while Chrome is frontmost.
final class ChromeController {
  private lazy var tabsScript = NSAppleScript(source: ChromeScripts.frontWindowTabs)
  private lazy var allTabsScript = NSAppleScript(source: ChromeScripts.allTabs)

  var isRunning: Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: ChromeScripts.bundleID).isEmpty
  }

  func frontWindowTabs() throws(ChromeError) -> TabSnapshot {
    guard isRunning else { throw .notRunning }
    guard let script = tabsScript else { throw .script(code: 0, message: "compile failed") }
    return TabSnapshot.parse(try execute(script).stringValue ?? "")
  }

  /// Every tab in every window.
  func allTabs() throws(ChromeError) -> [WindowTab] {
    guard isRunning else { throw .notRunning }
    guard let script = allTabsScript else { throw .script(code: 0, message: "compile failed") }
    return WindowTab.parseAll(try execute(script).stringValue ?? "")
  }

  func activateTab(windowID: Int, tabID: Int) throws(ChromeError) {
    try run(ChromeScripts.activateTab(windowID: windowID, tabID: tabID))
  }

  /// Gives keyboard focus back to Chrome after one of our panels had it.
  func focus() {
    NSRunningApplication.runningApplications(withBundleIdentifier: ChromeScripts.bundleID)
      .first?.activate()
  }

  func activateTab(id: Int) throws(ChromeError) {
    try run(ChromeScripts.activateTab(id: id))
  }

  /// The active tab's URL in the front window, or `nil` when there is none.
  func activeTabURL() throws(ChromeError) -> String? {
    guard isRunning else { throw .notRunning }
    guard let script = NSAppleScript(source: ChromeScripts.activeTabURL) else {
      throw .script(code: 0, message: "compile failed")
    }
    let url = try execute(script).stringValue ?? ""
    return url.isEmpty ? nil : url
  }

  func navigate(_ navigation: ChromeScripts.Navigation) throws(ChromeError) {
    try run(ChromeScripts.navigate(navigation))
  }

  func closeTab(id: Int) throws(ChromeError) {
    try run(ChromeScripts.closeTab(id: id))
  }

  func closeTabs(ids: [Int]) throws(ChromeError) {
    try run(ChromeScripts.closeTabs(ids: ids))
  }

  func setURL(tabID: Int, url: String) throws(ChromeError) {
    try run(ChromeScripts.setURL(tabID: tabID, url: url))
  }

  func moveTab(id: Int, to targetID: Int) throws(ChromeError) {
    try run(ChromeScripts.moveTab(id: id, to: targetID))
  }

  func openInNewTab(_ url: String) throws(ChromeError) {
    try run(ChromeScripts.openInNewTab(url))
  }

  private func run(_ source: String) throws(ChromeError) {
    guard let script = NSAppleScript(source: source) else {
      throw .script(code: 0, message: "compile failed")
    }
    _ = try execute(script)
  }

  private func execute(_ script: NSAppleScript) throws(ChromeError) -> NSAppleEventDescriptor {
    var errorInfo: NSDictionary?
    let result = script.executeAndReturnError(&errorInfo)
    guard let errorInfo else { return result }
    let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
    switch code {
    case -1743: throw .notAuthorized
    case -600: throw .notRunning
    default:
      throw .script(code: code, message: errorInfo[NSAppleScript.errorMessage] as? String ?? "")
    }
  }
}
