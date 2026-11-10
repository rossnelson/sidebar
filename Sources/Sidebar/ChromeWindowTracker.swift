import AppKit
import ApplicationServices
import SidebarCore

/// Chrome's focused browser window, as the frame around it needs it.
struct ChromeWindow: Equatable {
  /// Cocoa coordinates.
  var frame: CGRect
  var title: String?
  /// The window server's number, for ordering our frame next to it.
  var windowNumber: Int
  var isChromeFrontmost: Bool
}

/// Follows Chrome's focused browser window through the Accessibility API. Reports
/// `nil` when there is no such window on the current screen and Space.
final class ChromeWindowTracker {
  var onChange: (ChromeWindow?) -> Void = { _ in }

  private var observer: AXObserver?
  private var appElement: AXUIElement?
  private var observedPID: pid_t?
  private(set) var currentWindow: AXUIElement?

  private static let notifications = [
    kAXFocusedWindowChangedNotification,
    kAXMainWindowChangedNotification,
    kAXWindowMovedNotification,
    kAXWindowResizedNotification,
    kAXWindowMiniaturizedNotification,
    kAXWindowDeminiaturizedNotification,
    kAXWindowCreatedNotification,
    kAXUIElementDestroyedNotification,
  ]

  static func isTrusted(prompt: Bool) -> Bool {
    let key = "AXTrustedCheckOptionPrompt" as CFString
    return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
  }

  func start() {
    let center = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.didActivateApplicationNotification,
      NSWorkspace.didLaunchApplicationNotification,
      NSWorkspace.didTerminateApplicationNotification,
      NSWorkspace.activeSpaceDidChangeNotification,
      NSWorkspace.didHideApplicationNotification,
      NSWorkspace.didUnhideApplicationNotification,
    ] {
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.update() }
      }
    }
    update()
  }

  /// Re-reads Chrome's state and reports it.
  func update() {
    guard let chrome = NSRunningApplication
      .runningApplications(withBundleIdentifier: ChromeScripts.bundleID).first
    else {
      detach()
      return onChange(nil)
    }
    if observedPID != chrome.processIdentifier { attach(pid: chrome.processIdentifier) }

    guard !chrome.isHidden, let appElement,
      let (window, axFrame, number) = attachableWindow(of: appElement, pid: chrome.processIdentifier)
    else {
      currentWindow = nil
      return onChange(nil)
    }
    currentWindow = window
    onChange(ChromeWindow(
      frame: ScreenCoordinates.flip(axFrame, primaryScreenHeight: Self.primaryScreenHeight),
      title: copy(window, kAXTitleAttribute),
      windowNumber: number,
      isChromeFrontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier
        == chrome.processIdentifier))
  }

  /// Finds the window server's number for a window by owner and bounds. `nil`
  /// when it is not on screen, for example on another Space.
  private static func onScreenWindowNumber(pid: pid_t, axFrame: CGRect) -> Int? {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
      return nil
    }
    for info in list {
      guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
        (info[kCGWindowLayer as String] as? Int) == 0,
        let bounds = info[kCGWindowBounds as String] as? NSDictionary,
        let rect = CGRect(dictionaryRepresentation: bounds),
        abs(rect.minX - axFrame.minX) < 2, abs(rect.minY - axFrame.minY) < 2,
        abs(rect.width - axFrame.width) < 2, abs(rect.height - axFrame.height) < 2
      else { continue }
      return info[kCGWindowNumber as String] as? Int
    }
    return nil
  }

  /// Moves and resizes the current Chrome window. `frame` is in Cocoa coordinates.
  ///
  /// Chrome applies Accessibility frame changes asynchronously, one at a time:
  /// a size change sent right after a position change runs against the old
  /// position and drops the move. So change one value, wait until Chrome reports
  /// it, then change the next. Shrink before moving and move before growing, so
  /// the window never hangs off the screen (macOS would clamp it).
  func moveCurrentWindow(to frame: CGRect) async {
    guard let window = currentWindow else { return }
    let target = ScreenCoordinates.flip(frame, primaryScreenHeight: Self.primaryScreenHeight)

    for _ in 0..<3 {
      guard let current = frameInAXCoordinates(of: window) else { return }
      if current.isClose(to: target, within: 1) { return }
      let shrinking = target.width < current.width - 1 || target.height < current.height - 1
      if shrinking {
        await setSize(target.size, of: window)
        await setPosition(target.origin, of: window)
      } else {
        await setPosition(target.origin, of: window)
        await setSize(target.size, of: window)
      }
    }
  }

  private func setPosition(_ point: CGPoint, of window: AXUIElement) async {
    var point = point
    guard let value = AXValueCreate(.cgPoint, &point) else { return }
    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    await waitUntil { current in abs(current.minX - point.x) <= 1 && abs(current.minY - point.y) <= 1 }
  }

  private func setSize(_ size: CGSize, of window: AXUIElement) async {
    var size = size
    guard let value = AXValueCreate(.cgSize, &size) else { return }
    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    await waitUntil { current in abs(current.width - size.width) <= 1 && abs(current.height - size.height) <= 1 }
  }

  /// Polls the current window's frame (AX coordinates) for up to 300 ms.
  private func waitUntil(_ done: (CGRect) -> Bool) async {
    for _ in 0..<15 {
      if let window = currentWindow, let frame = frameInAXCoordinates(of: window), done(frame) { return }
      try? await Task.sleep(for: .milliseconds(20))
    }
  }

  // MARK: - Observer

  private func attach(pid: pid_t) {
    detach()
    var created: AXObserver?
    let callback: AXObserverCallback = { _, _, _, refcon in
      guard let refcon else { return }
      let tracker = Unmanaged<ChromeWindowTracker>.fromOpaque(refcon).takeUnretainedValue()
      MainActor.assumeIsolated { tracker.update() }
    }
    guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
    let element = AXUIElementCreateApplication(pid)
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    for name in Self.notifications {
      AXObserverAddNotification(created, element, name as CFString, refcon)
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
    observer = created
    appElement = element
    observedPID = pid
  }

  private func detach() {
    if let observer {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
    observer = nil
    appElement = nil
    observedPID = nil
    currentWindow = nil
  }

  // MARK: - Reading windows

  /// The browser window to frame: the focused window, else the main window, else
  /// the frontmost browser window. A floating window, such as a picture-in-picture
  /// video, can take focus; the frame then stays on the browser window behind it.
  /// A window counts only when it is on screen at the normal window level.
  private func attachableWindow(of app: AXUIElement, pid: pid_t) -> (AXUIElement, CGRect, Int)? {
    let preferred = [kAXFocusedWindowAttribute, kAXMainWindowAttribute].compactMap {
      copy(app, $0) as AXUIElement?
    }
    let all: [AXUIElement] = copy(app, kAXWindowsAttribute) ?? []
    for window in preferred + all where WindowRules.isAttachable(attributes(of: window)) {
      if let frame = frameInAXCoordinates(of: window),
        let number = Self.onScreenWindowNumber(pid: pid, axFrame: frame)
      {
        return (window, frame, number)
      }
    }
    return nil
  }

  private func attributes(of window: AXUIElement) -> WindowAttributes {
    WindowAttributes(
      role: copy(window, kAXRoleAttribute),
      subrole: copy(window, kAXSubroleAttribute),
      isModal: copy(window, kAXModalAttribute) ?? false,
      isMinimized: copy(window, kAXMinimizedAttribute) ?? false,
      isFullScreen: copy(window, "AXFullScreen") ?? false,
      document: copy(window, kAXDocumentAttribute),
      size: frameInAXCoordinates(of: window)?.size ?? .zero
    )
  }

  private func frameInAXCoordinates(of window: AXUIElement) -> CGRect? {
    guard let position: AXValue = copy(window, kAXPositionAttribute),
      let size: AXValue = copy(window, kAXSizeAttribute)
    else { return nil }
    var origin = CGPoint.zero
    var extent = CGSize.zero
    guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent)
    else { return nil }
    return CGRect(origin: origin, size: extent)
  }

  private func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
    else { return nil }
    return value as? T
  }

  private static var primaryScreenHeight: CGFloat {
    NSScreen.screens.first?.frame.maxY ?? 0
  }
}
