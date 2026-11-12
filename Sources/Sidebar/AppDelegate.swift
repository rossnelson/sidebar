import AppKit
import Carbon.HIToolbox
import OSLog
import SidebarCore

private let layoutLog = Logger(subsystem: "com.ross.sidebar", category: "layout")

final class AppDelegate: NSObject, NSApplicationDelegate {
  /// The width kept free left of Chrome for the sidebar and its gaps.
  static let sidebarWidth: CGFloat = 268
  /// The width kept free while collapsed: a thin strip to hover for the peek.
  static let margin: CGFloat = 8
  /// The space on each side of the sidebar.
  static let gap: CGFloat = 8

  private let model = SidebarModel()
  private let tracker = ChromeWindowTracker()
  private lazy var panel = SidebarPanel(model: model)
  private lazy var palette = PaletteController(model: model)
  private lazy var peekPanel = PeekPanel(model: model)
  private let preferences = Preferences()
  private lazy var settings = SettingsWindowController(preferences: preferences)
  private let toast = ToastController()
  private let preview = PreviewController()
  /// Copy the current URL. Registered only while Chrome is frontmost.
  private var copyURL: HotKey?
  private var peekHideTimer: Timer?
  private var swipeMonitor: Any?
  /// Horizontal and vertical travel of the current trackpad gesture.
  private var swipe = CGSize.zero
  /// Counts peek shows and hides, so an old slide-out does not hide a new peek.
  private var peekGeneration = 0
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
  /// After we move Chrome's window, its move and resize events describe
  /// half-finished frames. Ignore them until this time, then lay out once.
  private var settleUntil = Date.distantPast
  private var moveTask: Task<Void, Never>?
  private var clickMonitor: Any?
  private var localClickMonitor: Any?
  private var moveMonitors: [Any] = []
  /// Where Chrome's window sits, in screen coordinates.
  private var holeRect: CGRect?
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
    registerCopyURL()
    preferences.onChange = { [weak self] in self?.registerCopyURL() }
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
    model.switchSpace = { [weak self] in self?.switchSpace(to: $0) }
    model.openSettings = { [weak self] in self?.settings.show() }
    // A two-finger swipe across the sidebar moves to the next or previous space.
    swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      MainActor.assumeIsolated { self?.trackSwipe(event) }
      return event
    }
    model.notify = { [weak self] message, symbol in
      guard let self else { return }
      toast.show(message, systemImage: symbol, over: windowFrame)
    }
    model.showPreview = { [weak self] tab, row in
      guard let self else { return }
      guard let tab else {
        model.isPreviewing = false
        return preview.hide()
      }
      let window: NSWindow = model.isPeeking ? peekPanel : panel
      guard window.isVisible else { return }
      preview.show(tab, row: row, in: window, snapshot: model.snapshot, appearance: model.theme.appearance)
      model.isPreviewing = true
    }
    model.openPalette = { [weak self] in
      guard let self else { return }
      palette.show(over: windowFrame)
    }
    tracker.onChange = { [weak self] window in
      guard let self else { return }
      model.updateProfile(windowTitle: window?.title)
      if Date() < settleUntil {
        // Mid-move, the window can briefly read as missing or half-sized.
        if let window { chromeWindow = window }
        return
      }
      layout(window)
    }
    tracker.start()

    // A click in Chrome raises its window without an Accessibility event, and a
    // click in the sidebar can raise our frame. Put the frame back directly below
    // Chrome after each click.
    clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] _ in
      MainActor.assumeIsolated { self?.keepSidebarAboveChrome() }
    }
    localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
      MainActor.assumeIsolated { self?.keepSidebarAboveChrome() }
      return event
    }
    // The frame sits above Chrome, so it must let the mouse through over Chrome's
    // window. Transparent pixels alone do not: the frame would catch Chrome's clicks.
    let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
    if let global = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
      MainActor.assumeIsolated { self?.updateMousePassThrough() }
    }) { moveMonitors.append(global) }
    if let local = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
      MainActor.assumeIsolated { self?.updateMousePassThrough() }
      return event
    }) { moveMonitors.append(local) }

    model.loadFavorites()
    model.refreshSpaces()
    model.refreshTheme()
    model.refreshBookmarks()
    model.refreshRecents()
    schedule(every: 1) { [weak self] in
      guard let self else { return }
      // Recover from a missed Accessibility event (for example when a window
      // closes): while hidden, look for Chrome's window again.
      guard panel.isVisible else {
        if Date() > settleUntil { tracker.update() }
        return
      }
      guard chromeWindow?.isChromeFrontmost == true else { return }
      model.refreshTabs()
    }
    schedule(every: 5) { [weak self] in
      self?.model.refreshBookmarks()
      self?.model.refreshTheme()
      self?.model.refreshSpaces()
    }
    FaviconCache.shared.reload(profileDirectory: model.profileDirectory)
    schedule(every: 15) { [weak self] in
      guard let self, panel.isVisible else { return }
      model.refreshRecents()
      FaviconCache.shared.reload(profileDirectory: model.profileDirectory)
    }
  }

  // MARK: - Placement

  private func layout(_ window: ChromeWindow?) {
    layoutLog.debug("layout chrome=\(String(describing: window?.frame), privacy: .public) collapsed=\(self.model.isCollapsed)")
    chromeWindow = window
    guard let window else {
      peekPanel.orderOut(nil)
      return panel.orderOut(nil)
    }

    let screen = NSScreen.screens.first { $0.frame.intersects(window.frame) } ?? NSScreen.main
    let visible = screen?.visibleFrame ?? window.frame
    let width = model.isCollapsed ? Self.margin : Self.sidebarWidth
    // Chrome fills the screen right of the sidebar; no border around it.
    let layout = FrameLayout.compute(window: window.frame, screen: visible, sidebarWidth: width, margin: 0)
    // Correct the window once per move by the person; never chase Chrome's settling.
    if let moved = layout.windowFrame,
      !(requestedFrame?.isClose(to: window.frame, within: 12) ?? false)
    {
      moveChrome(to: moved)
    }
    let sidebar = model.isCollapsed
      ? FrameLayout.sidebar(beside: layout.hole, reserved: width, leftGap: 0, rightGap: 2)
      : FrameLayout.sidebar(beside: layout.hole, reserved: width, leftGap: Self.gap, rightGap: Self.gap)
    place(sidebar)
    holeRect = layout.hole
    updateMousePassThrough()
    // Sit directly above Chrome's window. The two do not overlap, so window
    // pickers (screenshots, screen recording) still choose Chrome over its area.
    let wasVisible = panel.isVisible
    panel.order(.above, relativeTo: window.windowNumber)
    if !wasVisible { model.refreshTabs() }
  }

  /// Turns on the Chrome-only hotkeys while Chrome is frontmost, so other apps keep these keys.
  private func updateCommandT() {
    let chromeInFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ChromeScripts.bundleID
    commandT?.isEnabled = chromeInFront
    copyURL?.isEnabled = chromeInFront
  }

  private func registerCopyURL() {
    let shortcut = preferences.copyURLShortcut
    copyURL = nil
    copyURL = HotKey(keyCode: Int(shortcut.keyCode), modifiers: shortcut.carbonModifiers, enabled: false) {
      [weak self] in self?.copyCurrentURL()
    }
    updateCommandT()
  }

  private func copyCurrentURL() {
    do {
      guard let url = try model.chrome.activeTabURL() else { return }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(url, forType: .string)
      toast.show("Copied URL", systemImage: "link", over: windowFrame)
    } catch .notAuthorized {
      model.problem = .automationDenied
    } catch {
      toast.show("Could not read the URL", systemImage: "exclamationmark.triangle", over: windowFrame)
    }
  }

  /// Lets the mouse through to Chrome while the pointer is over Chrome's window.
  private func updateMousePassThrough() {
    let overChrome = holeRect?.contains(NSEvent.mouseLocation) ?? false
    if panel.ignoresMouseEvents != overChrome { panel.ignoresMouseEvents = overChrome }
  }

  private func keepSidebarAboveChrome() {
    guard panel.isVisible, let number = chromeWindow?.windowNumber else { return }
    panel.order(.above, relativeTo: number)
  }

  private func place(_ sidebar: CGRect) {
    panel.appearance = model.theme.appearance
    // The content's width, in the panel's own coordinates.
    model.frameHole = CGRect(x: sidebar.width, y: 0, width: 0, height: sidebar.height)
    panel.setFrame(sidebar, display: true)
    // During the slide, commit each frame now; otherwise the window server
    // shows only the last one.
    CATransaction.flush()
    frameRect = sidebar
  }

  // MARK: - Spaces

  /// Brings the space's Chrome window to the front. With no window open for
  /// that profile, asks Chrome to open one, as its profile menu does.
  private func switchSpace(to space: SidebarModel.Space) {
    guard space.directory != model.spaceDirectory else { return }
    let base = ChromeProfile.defaultBase
    let profiles = (try? Data(contentsOf: base.appending(path: "Local State")))
      .map(ChromeProfiles.parse(localState:)) ?? []
    let raised = tracker.raiseWindow { title in
      ChromeProfiles.directory(forWindowTitle: title, profiles: profiles) == space.directory
    }
    guard !raised else { return }
    let open = Process()
    open.executableURL = URL(filePath: "/usr/bin/open")
    open.arguments = ["-nb", ChromeScripts.bundleID, "--args", "--profile-directory=\(space.directory)"]
    do {
      try open.run()
    } catch {
      toast.show("Could not open \(space.name)", systemImage: "exclamationmark.triangle", over: windowFrame)
    }
  }

  /// Adds up a trackpad gesture over the sidebar. A mostly horizontal gesture
  /// of 60 pt or more switches space when the fingers lift.
  private func trackSwipe(_ event: NSEvent) {
    guard event.window === panel || event.window === peekPanel, event.hasPreciseScrollingDeltas else { return }
    switch event.phase {
    case .began:
      swipe = .zero
    case .changed:
      swipe.width += event.scrollingDeltaX
      swipe.height += event.scrollingDeltaY
    case .ended:
      defer { swipe = .zero }
      guard abs(swipe.width) >= 60, abs(swipe.width) > abs(swipe.height) * 2 else { return }
      // Fingers moving left show the next space, as in Arc.
      if let space = model.neighborSpace(swipe.width < 0 ? 1 : -1) { switchSpace(to: space) }
    default:
      break
    }
  }

  // MARK: - Collapse and peek

  /// Collapses to a thin strip or expands. Chrome's left edge slides, and the
  /// sidebar slides with it: off the screen to the left, or back in.
  private func toggleCollapse() {
    model.showPreview(nil, .zero)
    hidePeek(animated: false)
    model.isCollapsed.toggle()
    guard let window = chromeWindow else { return }
    let delta = Self.sidebarWidth - Self.margin
    var frame = window.frame
    frame.origin.x += model.isCollapsed ? -delta : delta
    frame.size.width += model.isCollapsed ? delta : -delta
    moveChrome(to: frame, animated: true) { [weak self] chromeFrame in
      self?.place(FrameLayout.sidebar(
        beside: chromeFrame, reserved: Self.sidebarWidth, leftGap: Self.gap, rightGap: Self.gap))
    }
  }

  /// Moves Chrome's window step by step, ignoring its events until the move is
  /// done, then lays out once from where it really ended up.
  private func moveChrome(
    to frame: CGRect, animated: Bool = false, onStep: @escaping (CGRect) -> Void = { _ in }
  ) {
    layoutLog.debug("moveChrome to \(String(describing: frame), privacy: .public)")
    requestedFrame = frame
    settleUntil = .distantFuture
    moveTask?.cancel()
    moveTask = Task { [weak self] in
      guard let self else { return }
      await tracker.moveCurrentWindow(
        to: frame, animated: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
        onStep: onStep)
      guard !Task.isCancelled else { return }
      settleUntil = .distantPast
      tracker.update()
    }
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
    peekGeneration += 1
    // The same place and size as the open sidebar, over Chrome's left edge.
    let target = CGRect(
      x: frameRect.minX + Self.gap, y: frameRect.minY,
      width: Self.sidebarWidth - Self.gap * 2, height: frameRect.height)
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    peekPanel.appearance = model.theme.appearance
    // Start just off the screen's left edge and slide in; with Reduce Motion, fade in.
    peekPanel.setFrame(reduceMotion ? target : target.offsetBy(dx: -target.maxX, dy: 0), display: true)
    peekPanel.alphaValue = reduceMotion ? 0 : 1
    peekPanel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = reduceMotion ? 0.15 : 0.24
      context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
      peekPanel.animator().setFrame(target, display: true)
      peekPanel.animator().alphaValue = 1
    }
    model.refreshTabs()
  }

  /// Slides the peek back off the screen's left edge, or removes it at once.
  private func hidePeek(animated: Bool = true) {
    model.showPreview(nil, .zero)
    peekHideTimer?.invalidate()
    peekHideTimer = nil
    model.isPeeking = false
    peekGeneration += 1
    guard animated, peekPanel.isVisible else { return peekPanel.orderOut(nil) }
    let generation = peekGeneration
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let frame = peekPanel.frame
    NSAnimationContext.runAnimationGroup { context in
      context.duration = reduceMotion ? 0.12 : 0.18
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      if reduceMotion {
        peekPanel.animator().alphaValue = 0
      } else {
        peekPanel.animator().setFrame(frame.offsetBy(dx: -frame.maxX, dy: 0), display: true)
      }
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        // A new peek may have started while this one slid out.
        guard let self, generation == self.peekGeneration else { return }
        self.peekPanel.orderOut(nil)
        self.peekPanel.alphaValue = 1
      }
    }
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
    menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
      .target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit Sidebar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    item.menu = menu
    statusItem = item
  }

  @objc private func toggleFromMenu() { toggleCollapse() }

  @objc private func openSettings() { settings.show() }

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
