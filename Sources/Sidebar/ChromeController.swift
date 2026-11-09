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

  var isRunning: Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: ChromeScripts.bundleID).isEmpty
  }

  func frontWindowTabs() throws(ChromeError) -> TabSnapshot {
    guard isRunning else { throw .notRunning }
    guard let script = tabsScript else { throw .script(code: 0, message: "compile failed") }
    return TabSnapshot.parse(try execute(script).stringValue ?? "")
  }

  func activateTab(id: Int) throws(ChromeError) {
    try run(ChromeScripts.activateTab(id: id))
  }

  func closeTab(id: Int) throws(ChromeError) {
    try run(ChromeScripts.closeTab(id: id))
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
