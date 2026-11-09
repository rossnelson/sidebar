import AppKit
import Observation
import SidebarCore
import SwiftUI

/// State of the Cmd+T palette while it is open.
@Observable
final class PaletteState {
  var query = "" {
    didSet { selection = 0 }
  }
  var selection = 0
  var tabs: [WindowTab] = []
  var history: [HistoryItem] = []
  var bookmarks: [BookmarkNode] = []
  var theme = ProfileTheme.standard

  var results: [PaletteResult] {
    PaletteSearch.results(query: query, tabs: tabs, bookmarks: bookmarks, history: history)
  }

  func move(_ delta: Int) {
    let count = results.count
    guard count > 0 else { return }
    selection = (selection + delta + count) % count
  }
}

/// Owns the floating palette window. Cmd+T opens it over Chrome; Cmd+T again,
/// while it is open, opens a plain new tab.
final class PaletteController: NSObject, NSWindowDelegate {
  private let model: SidebarModel
  private let state = PaletteState()
  private var panel: PalettePanel?
  private var keyMonitor: Any?

  static let size = CGSize(width: 640, height: 420)

  init(model: SidebarModel) {
    self.model = model
  }

  var isOpen: Bool { panel?.isVisible ?? false }

  /// The Cmd+T action.
  func commandT(over windowFrame: CGRect?) {
    if isOpen {
      close()
      model.newTab()
    } else {
      show(over: windowFrame)
    }
  }

  func show(over windowFrame: CGRect?) {
    let sources = model.paletteSources()
    state.tabs = sources.tabs
    state.history = sources.history
    state.bookmarks = model.bookmarks
    state.theme = model.theme
    state.query = ""
    state.selection = 0

    let panel = self.panel ?? makePanel()
    // A fresh view each time, so the search field takes focus on appear.
    panel.contentView = NSHostingView(rootView: PaletteView(state: state, onOpen: open))
    panel.appearance = model.theme.appearance
    panel.setFrame(frame(over: windowFrame), display: true)
    panel.makeKeyAndOrderFront(nil)
    startKeyMonitor()
  }

  func close() {
    stopKeyMonitor()
    panel?.orderOut(nil)
    model.chrome.focus()
  }

  private func open(_ result: PaletteResult) {
    stopKeyMonitor()
    panel?.orderOut(nil)
    model.open(result)
    model.chrome.focus()
  }

  /// Closes the palette and replays a Chrome shortcut (⌘W, ⌘⇧T, ⌘1 …) in Chrome.
  private func forwardToChrome(_ event: NSEvent) {
    let keyCode = CGKeyCode(event.keyCode)
    let flags = event.cgEvent?.flags ?? []
    close()
    guard let pid = NSRunningApplication
      .runningApplications(withBundleIdentifier: ChromeScripts.bundleID).first?.processIdentifier
    else { return }
    Task {
      // Give Chrome a moment to take keyboard focus back from the palette.
      try? await Task.sleep(for: .milliseconds(80))
      for down in [true, false] {
        let key = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)
        key?.flags = flags
        key?.postToPid(pid)
      }
    }
  }

  private func openSelection() {
    let results = state.results
    guard results.indices.contains(state.selection) else {
      close()
      return model.newTab()
    }
    open(results[state.selection])
  }

  // MARK: - Window

  private func makePanel() -> PalettePanel {
    let panel = PalettePanel()
    panel.delegate = self
    self.panel = panel
    return panel
  }

  /// Centered over Chrome's window, a quarter of the way down.
  private func frame(over windowFrame: CGRect?) -> CGRect {
    let area = windowFrame ?? NSScreen.main?.visibleFrame ?? .zero
    let size = Self.size
    return CGRect(
      x: area.midX - size.width / 2,
      y: area.maxY - area.height * 0.22 - size.height,
      width: size.width, height: size.height)
  }

  func windowDidResignKey(_ notification: Notification) {
    guard isOpen else { return }
    stopKeyMonitor()
    panel?.orderOut(nil)
  }

  // MARK: - Keys

  private func startKeyMonitor() {
    stopKeyMonitor()
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, panel?.isKeyWindow == true else { return event }
      return handle(event) ? nil : event
    }
  }

  private func stopKeyMonitor() {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
  }

  private func handle(_ event: NSEvent) -> Bool {
    if KeyRouting.forwardsToChrome(keyCode: event.keyCode, modifiers: event.routingModifiers) {
      forwardToChrome(event)
      return true
    }
    let control = event.modifierFlags.contains(.control)
    switch (event.keyCode, control) {
    case (125, _), (45, true): state.move(1)  // ↓, ⌃N
    case (126, _), (35, true): state.move(-1)  // ↑, ⌃P
    case (36, _), (76, _): openSelection()  // Return, Enter
    case (53, _): close()  // Escape
    default: return false
    }
    return true
  }
}

final class PalettePanel: NSPanel {
  init() {
    super.init(
      contentRect: NSRect(origin: .zero, size: PaletteController.size),
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered, defer: false)
    level = .modalPanel
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    hidesOnDeactivate = false
    isMovable = false
    animationBehavior = .utilityWindow
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

// MARK: - View

struct PaletteView: View {
  @Bindable var state: PaletteState
  let onOpen: (PaletteResult) -> Void
  @FocusState private var focused: Bool

  var body: some View {
    let results = state.results
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 18))
          .foregroundStyle(.secondary)
        TextField("Search tabs, bookmarks, history, or the web", text: $state.query)
          .textFieldStyle(.plain)
          .font(.system(size: 20))
          .focused($focused)
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 16)

      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
              PaletteRow(result: result, selected: index == state.selection)
                .id(result.id)
                .onTapGesture { onOpen(result) }
                .onHover { if $0 { state.selection = index } }
            }
          }
          .padding(8)
        }
        .onChange(of: state.selection) { _, selection in
          if results.indices.contains(selection) { proxy.scrollTo(results[selection].id) }
        }
      }

      Divider()

      HStack(spacing: 14) {
        Hint(keys: "↵", label: "Open")
        Hint(keys: "↑↓", label: "Move")
        Hint(keys: "⌘T", label: "Blank tab")
        Hint(keys: "esc", label: "Close")
        Spacer()
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
    }
    .frame(width: PaletteController.size.width, height: PaletteController.size.height)
    .modifier(Themed(theme: state.theme, cornerRadius: 14))
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
    .onAppear { focused = true }
  }
}

private struct PaletteRow: View {
  let result: PaletteResult
  let selected: Bool

  var body: some View {
    HStack(spacing: 12) {
      icon.frame(width: 20, height: 20)
      VStack(alignment: .leading, spacing: 1) {
        Text(result.title).lineLimit(1).truncationMode(.tail)
        if showsURL {
          Text(result.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
      }
      Spacer(minLength: 8)
      Text(badge)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .modifier(RowStyle(highlighted: selected, hovering: false, cornerRadius: 8))
  }

  private var showsURL: Bool {
    switch result.kind {
    case .search, .url: false
    default: true
    }
  }

  @ViewBuilder private var icon: some View {
    switch result.kind {
    case .search: Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
    case .url: Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
    default: Favicon(url: result.url)
    }
  }

  private var badge: String {
    switch result.kind {
    case .tab: "Switch to Tab"
    case .bookmark: "Bookmark"
    case .history: "History"
    case .url: "Open"
    case .search: "Google"
    }
  }
}

private struct Hint: View {
  let keys: String
  let label: String

  var body: some View {
    HStack(spacing: 4) {
      Text(keys)
        .font(.caption.monospaced())
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
  }
}

extension NSEvent {
  var routingModifiers: KeyRouting.Modifiers {
    var result: KeyRouting.Modifiers = []
    if modifierFlags.contains(.command) { result.insert(.command) }
    if modifierFlags.contains(.shift) { result.insert(.shift) }
    if modifierFlags.contains(.option) { result.insert(.option) }
    if modifierFlags.contains(.control) { result.insert(.control) }
    return result
  }
}
