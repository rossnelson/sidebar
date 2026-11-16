import AppKit
import Carbon
import ScriptingBridge
import SidebarCore

enum ChromeError: Error, Equatable {
  /// macOS blocked the Apple Event (System Settings → Privacy & Security → Automation).
  case notAuthorized
  case notRunning
  case script(code: Int, message: String)
}

/// The person's own Chrome process. A test tool can start a second Google
/// Chrome with the same bundle ID; Sidebar never follows or controls that one.
@MainActor
enum ChromeProcess {
  /// The last choice, kept while the same Chrome processes run.
  private static var cached: (pids: [pid_t], choice: NSRunningApplication?)?

  static func current() -> NSRunningApplication? {
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: ChromeScripts.bundleID)
    if running.count < 2 { return running.first }
    let pids = running.map(\.processIdentifier)
    if let cached, cached.pids == pids { return cached.choice }
    let choice = ChromeInstance.pick(running.map { (id: $0, arguments: arguments(of: $0.processIdentifier)) })
    cached = (pids, choice)
    return choice
  }

  /// The process's command-line arguments, from the kernel.
  static func arguments(of pid: pid_t) -> [String] {
    var mib = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
    // An argument count, the executable path, padding, then the arguments.
    let count = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
    let parts = buffer[4..<size].split(separator: 0, omittingEmptySubsequences: true)
    return parts.dropFirst().prefix(count).map { String(decoding: $0, as: UTF8.self) }
  }
}

/// Talks to Chrome through Apple Events sent with ScriptingBridge to one
/// process, so a second Chrome that a test tool started never answers. Runs on
/// the main thread: each call is a few milliseconds, and the sidebar only polls
/// while Chrome is frontmost.
final class ChromeController: NSObject, SBApplicationDelegate {
  private var app: SBApplication?
  private var appPID: pid_t?
  /// The error of the last Apple Event that failed, if any.
  private var lastError: NSError?

  var isRunning: Bool { ChromeProcess.current() != nil }

  func frontWindowTabs() throws(ChromeError) -> TabSnapshot {
    let chrome = try connect()
    guard let window = try first(chrome.value(forKey: "windows")) else { return .empty }
    let tabs = try elements(window.value(forKey: "tabs"))
    let ids = (tabs.value(forKey: "id") as? [Any]) ?? []
    let titles = (tabs.value(forKey: "title") as? [String]) ?? []
    let urls = (tabs.value(forKey: "URL") as? [String]) ?? []
    let loads = (tabs.value(forKey: "loading") as? [Bool]) ?? []
    let active = (window.value(forKey: "activeTabIndex") as? Int) ?? 0
    try check()
    let list = ids.indices.compactMap { i -> ChromeTab? in
      guard let id = Self.number(ids[i]), i < urls.count else { return nil }
      return ChromeTab(
        id: id, title: i < titles.count ? titles[i] : "", url: urls[i], isLoading: i < loads.count && loads[i])
    }
    return TabSnapshot(tabs: list, activeIndex: active)
  }

  /// Every tab in every window.
  func allTabs() throws(ChromeError) -> [WindowTab] {
    let chrome = try connect()
    var result: [WindowTab] = []
    for case let window as SBObject in try elements(chrome.value(forKey: "windows")) {
      guard let windowID = Self.number(window.value(forKey: "id") as Any) else { continue }
      let tabs = try elements(window.value(forKey: "tabs"))
      let ids = (tabs.value(forKey: "id") as? [Any]) ?? []
      let titles = (tabs.value(forKey: "title") as? [String]) ?? []
      let urls = (tabs.value(forKey: "URL") as? [String]) ?? []
      for i in ids.indices {
        guard let id = Self.number(ids[i]), i < urls.count else { continue }
        result.append(WindowTab(windowID: windowID, tab: ChromeTab(id: id, title: i < titles.count ? titles[i] : "", url: urls[i])))
      }
    }
    try check()
    return result
  }

  /// Switches to a tab in any window and brings that window to the front.
  func activateTab(windowID: Int, tabID: Int) throws(ChromeError) {
    let chrome = try connect()
    for case let window as SBObject in try elements(chrome.value(forKey: "windows")) {
      guard Self.number(window.value(forKey: "id") as Any) == windowID else { continue }
      if let index = try tabIndex(of: tabID, in: window) { window.setValue(index, forKey: "activeTabIndex") }
      window.setValue(1, forKey: "index")
      break
    }
    try check()
    focus()
  }

  /// Gives keyboard focus back to Chrome after one of our panels had it.
  func focus() {
    ChromeProcess.current()?.activate()
  }

  func activateTab(id: Int) throws(ChromeError) {
    let window = try frontWindow()
    if let index = try tabIndex(of: id, in: window) { window.setValue(index, forKey: "activeTabIndex") }
    try check()
  }

  /// The active tab's URL in the front window, or `nil` when there is none.
  func activeTabURL() throws(ChromeError) -> String? {
    let chrome = try connect()
    guard let window = try first(chrome.value(forKey: "windows")) else { return nil }
    let tab = window.value(forKey: "activeTab") as? SBObject
    let url = tab?.value(forKey: "URL") as? String
    try check()
    return (url?.isEmpty ?? true) ? nil : url
  }

  func navigate(_ navigation: ChromeScripts.Navigation) throws(ChromeError) {
    let chrome = try connect()
    guard let window = try first(chrome.value(forKey: "windows")),
      let tab = window.value(forKey: "activeTab") as? SBObject
    else { return }
    switch navigation {
    case .back: try send(tab, "goBack")
    case .forward: try send(tab, "goForward")
    case .reload: try send(tab, "reload")
    }
  }

  func closeTab(id: Int) throws(ChromeError) {
    try closeTabs(ids: [id])
  }

  /// Closes tabs of the front window, from the last back, so closing one does
  /// not shift the ones still to check.
  func closeTabs(ids: [Int]) throws(ChromeError) {
    let window = try frontWindow()
    let tabs = try elements(window.value(forKey: "tabs"))
    let tabIDs = ((tabs.value(forKey: "id") as? [Any]) ?? []).map(Self.number)
    let doomed = Set(ids)
    for i in tabIDs.indices.reversed() {
      guard let id = tabIDs[i], doomed.contains(id), let tab = tabs.object(at: i) as? SBObject else { continue }
      try send(tab, "close")
    }
  }

  /// Loads `url` in one tab of the front window, for a pinned tab going home.
  func setURL(tabID: Int, url: String) throws(ChromeError) {
    let window = try frontWindow()
    guard let index = try tabIndex(of: tabID, in: window),
      let tab = try elements(window.value(forKey: "tabs")).object(at: index - 1) as? SBObject
    else { return }
    tab.setValue(url, forKey: "URL")
    try check()
  }

  /// Opens `url` in a new tab of the front window, or a new window when none is open.
  func openInNewTab(_ url: String) throws(ChromeError) {
    let chrome = try connect()
    if try elements(chrome.value(forKey: "windows")).count == 0 {
      try make("cwin", in: nil, properties: [:])
      guard let window = try first(chrome.value(forKey: "windows")),
        let tab = window.value(forKey: "activeTab") as? SBObject
      else { return }
      tab.setValue(url, forKey: "URL")
      try check()
    } else {
      try make("CrTb", in: 1, properties: ["URL ": url])
    }
  }

  /// Sends `make new <kind> at window <index> with properties {…}` to the
  /// chosen Chrome process. ScriptingBridge cannot make new elements from
  /// Swift, so this one command is a plain Apple Event.
  private func make(_ kind: String, in windowIndex: Int32?, properties: [String: String]) throws(ChromeError) {
    var parameters = [Self.code("kocl"): NSAppleEventDescriptor(typeCode: Self.code(kind))]
    if let windowIndex { parameters[Self.code("insh")] = Self.windowSpecifier(index: windowIndex) }
    let values = NSAppleEventDescriptor.record()
    for (key, value) in properties { values.setDescriptor(NSAppleEventDescriptor(string: value), forKeyword: Self.code(key)) }
    parameters[Self.code("prdt")] = values
    try send(Self.code("core"), Self.code("crel"), parameters)
  }

  /// Sends one Apple Event to the chosen Chrome process and waits for the reply.
  private func send(_ eventClass: AEEventClass, _ eventID: AEEventID, _ parameters: [AEKeyword: NSAppleEventDescriptor]) throws(ChromeError) {
    guard let pid = appPID else { throw .notRunning }
    var process = pid
    guard let target = NSAppleEventDescriptor(
      descriptorType: typeKernelProcessID, bytes: &process, length: MemoryLayout<pid_t>.size)
    else { throw .notRunning }
    let event = NSAppleEventDescriptor(
      eventClass: eventClass, eventID: eventID, targetDescriptor: target,
      returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    for (key, value) in parameters { event.setDescriptor(value, forKeyword: key) }
    do {
      _ = try event.sendEvent(options: [.waitForReply], timeout: 2)
    } catch {
      lastError = error as NSError
      try check()
    }
  }

  /// `window <index>`.
  private static func windowSpecifier(index: Int32) -> NSAppleEventDescriptor {
    specifier(want: "cwin", index: index, from: .null())
  }

  private static func specifier(want: String, index: Int32, from container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
    let record = NSAppleEventDescriptor.record()
    record.setDescriptor(NSAppleEventDescriptor(typeCode: code(want)), forKeyword: code("want"))
    record.setDescriptor(NSAppleEventDescriptor(enumCode: code("indx")), forKeyword: code("form"))
    record.setDescriptor(NSAppleEventDescriptor(int32: index), forKeyword: code("seld"))
    record.setDescriptor(container, forKeyword: code("from"))
    return record.coerce(toDescriptorType: typeObjectSpecifier) ?? record
  }

  private static func code(_ text: String) -> FourCharCode {
    text.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
  }

  // MARK: - Apple Events

  /// The ScriptingBridge object for the person's Chrome process.
  private func connect() throws(ChromeError) -> SBApplication {
    guard let process = ChromeProcess.current() else { throw .notRunning }
    lastError = nil
    if let app, appPID == process.processIdentifier { return app }
    guard let made = SBApplication(processIdentifier: process.processIdentifier) else { throw .notRunning }
    made.delegate = self
    // Fail in a short time instead of blocking the main thread for minutes.
    made.timeout = 120  // ticks of 1/60 s: 2 seconds
    app = made
    appPID = process.processIdentifier
    return made
  }

  private func frontWindow() throws(ChromeError) -> SBObject {
    guard let window = try first(try connect().value(forKey: "windows")) else { throw .script(code: 0, message: "no window") }
    return window
  }

  private func elements(_ value: Any?) throws(ChromeError) -> SBElementArray {
    try check()
    return value as? SBElementArray ?? SBElementArray()
  }

  /// The first element, which for windows is the front window.
  private func first(_ value: Any?) throws(ChromeError) -> SBObject? {
    let list = try elements(value)
    guard list.count > 0 else { return nil }
    return list.object(at: 0) as? SBObject
  }

  /// The tab's 1-based place in the window.
  private func tabIndex(of id: Int, in window: SBObject) throws(ChromeError) -> Int? {
    let ids = ((try elements(window.value(forKey: "tabs")).value(forKey: "id") as? [Any]) ?? []).map(Self.number)
    try check()
    return ids.firstIndex(of: id).map { $0 + 1 }
  }

  private func send(_ object: SBObject, _ command: String) throws(ChromeError) {
    lastError = nil
    _ = object.perform(NSSelectorFromString(command))
    try check()
  }

  /// Throws the error of the last failed Apple Event.
  private func check() throws(ChromeError) {
    guard let error = lastError else { return }
    lastError = nil
    switch error.code {
    case -1743: throw .notAuthorized
    case -600, -609: throw .notRunning
    default: throw .script(code: error.code, message: error.localizedDescription)
    }
  }

  func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: any Error) -> Any? {
    lastError = error as NSError
    return nil
  }

  /// Chrome reports IDs as numbers or, in some versions, as text.
  private static func number(_ value: Any) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    if let text = value as? String { return Int(text) }
    return nil
  }
}
