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
  private lazy var peekPanel = PeekPanel(model: model)
  private var peekHideTimer: Timer?
  /// Our frame window's last frame, for placing the peek.
  private var frameRect: CGRect?
  private var statusItem: NSStatusItem?
  private var hotKey: HotKey?
  /// Cmd+T. Registered only while Chrome is frontmost, so other apps keep their Cmd+T.
  private var commandT: HotKey?
  private var timers: [Timer] = []
  private var chromeWindow: ChromeWindow?
  /// The last frame we asked Chrome's window to take. Chrome settles near it, not on it.
  private var requestedFrame: CGRect?
  private var windowFrame: CGRect? { chromeWindow?.frame }

  func applicationDidFinishLaunching(_ notification: Notification) {
    makeStatusItem()
    hotKey = HotKey(keyCode: kVK_ANSI_S, modifiers: controlKey | cmdKey) { [weak self] in
      self?.toggleCollapse()
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

    model.toggleCollapse = { [weak self] in self?.toggleCollapse() }
    model.setPeeking = { [weak self] in self?.setPeeking($0) }
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
    guard let window else {
      peekPanel.orderOut(nil)
      return panel.orderOut(nil)
    }

    let screen = NSScreen.screens.first { $0.frame.intersects(window.frame) } ?? NSScreen.main
    let visible = screen?.visibleFrame ?? window.frame
    let layout = FrameLayout.compute(
      window: window.frame, screen: visible,
      sidebarWidth: model.isCollapsed ? Self.margin : Self.sidebarWidth, margin: Self.margin)
    // Correct the window once per move by the person; never chase Chrome's settling.
    if let moved = layout.windowFrame,
      !(requestedFrame?.isClose(to: window.frame, within: 12) ?? false)
    {
      requestedFrame = moved
      tracker.setCurrentWindowFrame(moved)
    }
    panel.appearance = model.theme.appearance
    model.frameHole = layout.holeInFrame
    panel.setFrame(layout.frame, display: true)
    frameRect = layout.frame
    // Sit directly below Chrome's window: above other apps' windows, never over Chrome.
    let wasVisible = panel.isVisible
    panel.order(.below, relativeTo: window.windowNumber)
    if !wasVisible { model.refreshTabs() }
  }

  private func updateCommandT() {
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    commandT?.isEnabled = front == ChromeScripts.bundleID
  }

  // MARK: - Collapse and peek

  /// Collapses to the border or expands, moving Chrome's window into or out of
  /// the sidebar's space so the whole frame keeps its size.
  private func toggleCollapse() {
    hidePeek()
    model.isCollapsed.toggle()
    guard var window = chromeWindow else { return }
    let delta = Self.sidebarWidth - Self.margin
    var frame = window.frame
    if model.isCollapsed {
      frame.origin.x -= delta
      frame.size.width += delta
    } else {
      frame.origin.x += delta
      frame.size.width -= delta
    }
    requestedFrame = frame
    tracker.setCurrentWindowFrame(frame)
    window.frame = frame
    layout(window)
  }

  private func setPeeking(_ peeking: Bool) {
    peekHideTimer?.invalidate()
    peekHideTimer = nil
    guard peeking else {
      // A short delay, so moving between the border and the peek does not close it.
      let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated { self?.hidePeek() }
      }
      RunLoop.main.add(timer, forMode: .common)
      peekHideTimer = timer
      return
    }
    guard model.isCollapsed, let frameRect, !model.isPeeking else { return }
    model.isPeeking = true
    peekPanel.appearance = model.theme.appearance
    peekPanel.setFrame(
      CGRect(
        x: frameRect.minX + 4, y: frameRect.minY + Self.margin,
        width: Self.sidebarWidth - 8, height: frameRect.height - Self.margin * 2),
      display: true)
    peekPanel.orderFrontRegardless()
    model.refreshTabs()
  }

  private func hidePeek() {
    peekHideTimer?.invalidate()
    peekHideTimer = nil
    model.isPeeking = false
    peekPanel.orderOut(nil)
  }

  // MARK: - Menu bar

  private func makeStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Sidebar")
    let menu = NSMenu()
    menu.addItem(withTitle: "Collapse or Expand Sidebar (⌃⌘S)", action: #selector(toggleFromMenu), keyEquivalent: "")
      .target = self
    menu.addItem(withTitle: "Reload Bookmarks and History", action: #selector(reload), keyEquivalent: "")
      .target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit Sidebar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    item.menu = menu
    statusItem = item
  }

  @objc private func toggleFromMenu() { toggleCollapse() }

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
