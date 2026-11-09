import AppKit
import Carbon.HIToolbox
import SidebarCore

final class AppDelegate: NSObject, NSApplicationDelegate {
  static let sidebarWidth: CGFloat = 260
  /// The frame's width on Chrome's other three sides.
  static let margin: CGFloat = 8

  private let model = SidebarModel()
  private let tracker = ChromeWindowTracker()
  private lazy var panel = SidebarPanel(model: model)
  private lazy var palette = PaletteController(model: model)
  private var statusItem: NSStatusItem?
  private var hotKey: HotKey?
  /// Cmd+T. Registered only while Chrome is frontmost, so other apps keep their Cmd+T.
  private var commandT: HotKey?
  private var timers: [Timer] = []
  private var userHidden = false
  private var chromeWindow: ChromeWindow?
  private var windowFrame: CGRect? { chromeWindow?.frame }

  func applicationDidFinishLaunching(_ notification: Notification) {
    makeStatusItem()
    hotKey = HotKey(keyCode: kVK_ANSI_S, modifiers: controlKey | cmdKey) { [weak self] in
      self?.toggle()
    }
    commandT = HotKey(keyCode: kVK_ANSI_T, modifiers: cmdKey, enabled: false) { [weak self] in
      guard let self else { return }
      palette.commandT(over: windowFrame)
    }
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.updateCommandT() }
    }
    updateCommandT()

    if !ChromeWindowTracker.isTrusted(prompt: true) {
      model.problem = .accessibilityDenied
      // Keep checking until the person grants the permission.
      schedule(every: 2) { [weak self] in
        guard let self, ChromeWindowTracker.isTrusted(prompt: false) else { return }
        if model.problem == .accessibilityDenied { model.problem = nil }
        tracker.update()
      }
    }

    model.openPalette = { [weak self] in
      guard let self else { return }
      palette.show(over: windowFrame)
    }
    tracker.onChange = { [weak self] window in
      self?.model.updateProfile(windowTitle: window?.title)
      self?.layout(window)
    }
    tracker.start()

    model.loadFavorites()
    model.refreshTheme()
    model.refreshBookmarks()
    model.refreshRecents()
    schedule(every: 1) { [weak self] in
      guard let self, panel.isVisible, chromeWindow?.isChromeFrontmost == true else { return }
      model.refreshTabs()
    }
    schedule(every: 5) { [weak self] in
      self?.model.refreshBookmarks()
      self?.model.refreshTheme()
    }
    schedule(every: 15) { [weak self] in
      guard let self, panel.isVisible else { return }
      model.refreshRecents()
    }
  }

  // MARK: - Placement

  private func layout(_ window: ChromeWindow?) {
    chromeWindow = window
    guard let window, !userHidden else { return panel.orderOut(nil) }

    let screen = NSScreen.screens.first { $0.frame.intersects(window.frame) } ?? NSScreen.main
    let visible = screen?.visibleFrame ?? window.frame
    let layout = FrameLayout.compute(
      window: window.frame, screen: visible, sidebarWidth: Self.sidebarWidth, margin: Self.margin)
    if let moved = layout.windowFrame {
      // Moving the window fires a move notification, which lays out again.
      tracker.setCurrentWindowFrame(moved)
    }
    panel.appearance = model.theme.appearance
    model.frameHole = layout.holeInFrame
    panel.setFrame(layout.frame, display: true)
    // Sit directly below Chrome's window: above other apps' windows, never over Chrome.
    let wasVisible = panel.isVisible
    panel.order(.below, relativeTo: window.windowNumber)
    if !wasVisible { model.refreshTabs() }
  }

  private func updateCommandT() {
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    commandT?.isEnabled = front == ChromeScripts.bundleID
  }

  private func toggle() {
    userHidden.toggle()
    layout(chromeWindow)
  }

  // MARK: - Menu bar

  private func makeStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Sidebar")
    let menu = NSMenu()
    menu.addItem(withTitle: "Toggle Sidebar (⌃⌘S)", action: #selector(toggleFromMenu), keyEquivalent: "")
      .target = self
    menu.addItem(withTitle: "Reload Bookmarks and History", action: #selector(reload), keyEquivalent: "")
      .target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit Sidebar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    item.menu = menu
    statusItem = item
  }

  @objc private func toggleFromMenu() { toggle() }

  @objc private func reload() {
    model.refreshBookmarks()
    model.refreshRecents()
    model.refreshTabs()
  }

  private func schedule(every seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) {
    let timer = Timer(timeInterval: seconds, repeats: true) { _ in
      MainActor.assumeIsolated { action() }
    }
    RunLoop.main.add(timer, forMode: .common)
    timers.append(timer)
  }
}
