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
  var archived: [ArchivedTab] = []
  var commands: [PaletteCommand] = []
  var theme = ProfileTheme.standard

  var isCommandMode: Bool { query.trimmingCharacters(in: .whitespaces).hasPrefix(">") }

  var results: [PaletteResult] {
    PaletteSearch.results(
      query: query, tabs: tabs, bookmarks: bookmarks, history: history, archived: archived, commands: commands)
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
    state.archived = model.archived
    state.commands = model.commands
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
    fadeOut()
    model.chrome.focus()
  }

  private func open(_ result: PaletteResult) {
    stopKeyMonitor()
    fadeOut()
    model.open(result)
    model.chrome.focus()
  }

  /// A quick fade instead of vanishing.
  private func fadeOut() {
    guard let panel, panel.isVisible else { return }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.12
      panel.animator().alphaValue = 0
    } completionHandler: {
      MainActor.assumeIsolated {
        panel.orderOut(nil)
        panel.alphaValue = 1
      }
    }
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
  /// Room around the palette inside its window, for the palette's own shadow.
  static let shadowMargin: CGFloat = 48

  private func frame(over windowFrame: CGRect?) -> CGRect {
    let area = windowFrame ?? NSScreen.main?.visibleFrame ?? .zero
    let size = Self.size
    let margin = Self.shadowMargin
    // The palette hangs from its top edge and grows downward with its results.
    return CGRect(
      x: area.midX - size.width / 2 - margin,
      y: area.maxY - area.height * 0.22 - size.height - margin,
      width: size.width + margin * 2, height: size.height + margin * 2)
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
    if let action = Self.editAction(for: event) {
      // A menu-bar app has no Edit menu, so send the edit command to the text field directly.
      return NSApp.sendAction(action, to: nil, from: nil)
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

extension PaletteController {
  /// ⌘X, ⌘C, ⌘V, ⌘A, ⌘Z and ⇧⌘Z, which an Edit menu would normally handle.
  static func editAction(for event: NSEvent) -> Selector? {
    let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
    switch (event.keyCode, flags) {
    case (7, .command): return #selector(NSText.cut(_:))
    case (8, .command): return #selector(NSText.copy(_:))
    case (9, .command): return #selector(NSText.paste(_:))
    case (0, .command): return #selector(NSText.selectAll(_:))
    case (6, .command): return Selector(("undo:"))
    case (6, [.command, .shift]): return Selector(("redo:"))
    default: return nil
    }
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
    // The view draws its own shadow, which follows its changing height.
    hasShadow = false
    hidesOnDeactivate = false
    isMovable = false
    // The view animates its own entrance.
    animationBehavior = .none
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

// MARK: - View

struct PaletteView: View {
  @Bindable var state: PaletteState
  let onOpen: (PaletteResult) -> Void
  @FocusState private var focused: Bool
  @State private var appeared = false
  @Namespace private var highlight
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  static let cornerRadius: CGFloat = 22

  /// Tall enough for the results, up to the full size: the field, the rows and the key hints.
  private func height(for results: [PaletteResult]) -> CGFloat {
    let rows = results.reduce(CGFloat(0)) { total, result in
      switch result.kind {
      case .search, .url, .command: total + 35
      default: total + 51
      }
    }
    let chrome: CGFloat = 58 + 1 + 16 + 38
    return min(PaletteController.size.height, chrome + max(rows, 35))
  }

  var body: some View {
    let results = state.results
    let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    let accent = Color(SpaceColors.palette(for: state.theme, dark: colorScheme == .dark).accent)
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: state.isCommandMode ? "chevron.right" : "magnifyingglass")
          .font(.system(size: 17, weight: .medium))
          .foregroundStyle(.secondary)
          .contentTransition(.symbolEffect(.replace))
          .symbolEffect(.bounce, value: state.query.isEmpty)
          .frame(width: 20)
        TextField("Search tabs, bookmarks, history, or the web. Type > for commands", text: $state.query)
          .textFieldStyle(.plain)
          .font(.system(size: 19))
          .kerning(-0.2)
          .focused($focused)
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 17)

      LinearGradient(colors: [.clear, .primary.opacity(0.12), .clear], startPoint: .leading, endPoint: .trailing)
        .frame(height: 0.5)

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
              PaletteRow(result: result, selected: index == state.selection, highlight: highlight)
                .id(result.id)
                .onTapGesture { onOpen(result) }
                // Only a moving pointer selects; rows scrolling under a still one do not.
                .onContinuousHover { phase in
                  if case .active = phase, state.selection != index { state.selection = index }
                }
                .cascadeIn(delay: Motion.stagger(index, step: 0.018, cap: 10), distance: 5)
            }
          }
          .padding(8)
          .motion(.snappy(duration: 0.16), value: state.selection)
        }
        .scrollIndicators(.never)
        .onChange(of: state.selection) { _, selection in
          if results.indices.contains(selection) { proxy.scrollTo(results[selection].id) }
        }
      }

      LinearGradient(colors: [.clear, .primary.opacity(0.1), .clear], startPoint: .leading, endPoint: .trailing)
        .frame(height: 0.5)

      HStack(spacing: 16) {
        Hint(symbols: ["return"], label: "Open")
        Hint(symbols: ["arrow.up", "arrow.down"], label: "Move")
        Hint(symbols: ["command"], text: "T", label: "Blank tab")
        Hint(symbols: ["escape"], label: "Close")
        Spacer()
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 10)
    }
    .frame(width: PaletteController.size.width, height: height(for: results))
    .modifier(Themed(theme: state.theme, cornerRadius: Self.cornerRadius, fillsBackground: false))
    .glassEffect(.regular.tint(accent.opacity(0.18)), in: shape)
    .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
    .background(shape.fill(.black.opacity(0.001)).shadow(color: .black.opacity(0.28), radius: 28, y: 14))
    .motion(.spring(response: 0.32, dampingFraction: 0.86), value: height(for: results))
    .padding(PaletteController.shadowMargin)
    .frame(
      width: PaletteController.size.width + PaletteController.shadowMargin * 2,
      height: PaletteController.size.height + PaletteController.shadowMargin * 2,
      alignment: .top)
    .scaleEffect(appeared || reduceMotion ? 1 : 0.94, anchor: .top)
    .opacity(appeared ? 1 : 0)
    .blur(radius: appeared || reduceMotion ? 0 : 6)
    .onAppear {
      focused = true
      withAnimation(Motion.animation(.spring(response: 0.3, dampingFraction: 0.8), reduceMotion: reduceMotion)) {
        appeared = true
      }
    }
  }
}

private struct PaletteRow: View {
  let result: PaletteResult
  let selected: Bool
  let highlight: Namespace.ID
  @Environment(\.sidebarColors) private var colors

  var body: some View {
    HStack(spacing: 12) {
      icon
        .frame(width: 22, height: 22)
        .scaleEffect(selected ? 1.08 : 1)
      VStack(alignment: .leading, spacing: 2) {
        Text(result.title)
          .font(.system(size: 13.5, weight: selected ? .semibold : .medium))
          .kerning(-0.1)
          .lineLimit(1)
          .truncationMode(.tail)
        if showsURL {
          Text(result.url)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      Spacer(minLength: 8)
      HStack(spacing: 6) {
        Text(badge.uppercased())
          .font(.system(size: 10, weight: .semibold))
          .kerning(0.6)
          .foregroundStyle(.secondary)
        if selected {
          Image(systemName: "return")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
            .transition(.scale(scale: 0.4).combined(with: .opacity))
        }
      }
      .opacity(selected || result.kind == .search ? 1 : 0.55)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .background {
      if selected {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(colors.selected)
          .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
          .matchedGeometryEffect(id: "palette-highlight", in: highlight)
      }
    }
  }

  private var showsURL: Bool {
    switch result.kind {
    case .search, .url, .command: false
    default: true
    }
  }

  @ViewBuilder private var icon: some View {
    switch result.kind {
    case .search: Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
    case .url: Image(systemName: "arrow.up.right").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
    case .command:
      Image(systemName: result.symbol ?? "command")
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.secondary)
        .symbolEffect(.bounce, value: selected)
    default: Favicon(url: result.url, size: 18)
    }
  }

  private var badge: String {
    switch result.kind {
    case .tab: "Switch to Tab"
    case .bookmark: "Bookmark"
    case .history: "History"
    case .url: "Open"
    case .search: "Google"
    case .archived: "Archived"
    case .command: "Command"
    }
  }
}

/// A key hint: SF Symbol keycaps and a label.
private struct Hint: View {
  let symbols: [String]
  var text: String?
  let label: String

  var body: some View {
    HStack(spacing: 5) {
      HStack(spacing: 2) {
        ForEach(symbols, id: \.self) { symbol in
          Image(systemName: symbol)
        }
        if let text { Text(text) }
      }
      .font(.system(size: 9.5, weight: .semibold, design: .rounded))
      .padding(.horizontal, 5)
      .frame(minWidth: 18, minHeight: 17)
      .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
      Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
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
