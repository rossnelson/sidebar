import AppKit
import ApplicationServices
import SidebarCore

/// Follows Chrome's focused browser window through the Accessibility API and
/// reports its frame (Cocoa coordinates) and title, or `nil` when the sidebar should hide.
final class ChromeWindowTracker {
  var onChange: (_ frame: CGRect?, _ title: String?) -> Void = { _, _ in }

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
      return report(nil, title: nil)
    }
    if observedPID != chrome.processIdentifier { attach(pid: chrome.processIdentifier) }

    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == chrome.processIdentifier,
      let appElement, let window = attachableWindow(of: appElement), let frame = frame(of: window)
    else {
      currentWindow = nil
      return report(nil, title: nil)
    }
    currentWindow = window
    report(frame, title: copy(window, kAXTitleAttribute))
  }

  /// Moves and resizes the current Chrome window. `frame` is in Cocoa coordinates.
  func setCurrentWindowFrame(_ frame: CGRect) {
    guard let window = currentWindow else { return }
    let ax = ScreenCoordinates.flip(frame, primaryScreenHeight: Self.primaryScreenHeight)
    var origin = ax.origin
    var size = ax.size
    if let value = AXValueCreate(.cgPoint, &origin) {
      AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }
    if let value = AXValueCreate(.cgSize, &size) {
      AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    }
  }

  private func report(_ frame: CGRect?, title: String?) { onChange(frame, title) }

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

  private func attachableWindow(of app: AXUIElement) -> AXUIElement? {
    for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
      if let window: AXUIElement = copy(app, attribute), WindowRules.isAttachable(attributes(of: window)) {
        return window
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

  private func frame(of window: AXUIElement) -> CGRect? {
    frameInAXCoordinates(of: window).map {
      ScreenCoordinates.flip($0, primaryScreenHeight: Self.primaryScreenHeight)
    }
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
