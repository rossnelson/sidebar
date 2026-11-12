import AppKit
import Carbon.HIToolbox
import Observation
import SidebarCore
import SwiftUI

/// Saved preferences that a person can change in the Settings window.
@Observable
final class Preferences {
  var copyURLShortcut: Shortcut {
    didSet {
      if let data = try? JSONEncoder().encode(copyURLShortcut) {
        UserDefaults.standard.set(data, forKey: Self.copyURLKey)
      }
      onChange()
    }
  }

  /// Called after any change, so the app can register the new hotkeys.
  @ObservationIgnored var onChange: () -> Void = {}

  private static let copyURLKey = "copyURLShortcut"

  init() {
    copyURLShortcut = UserDefaults.standard.data(forKey: Self.copyURLKey)
      .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .copyURLDefault
  }
}

extension Shortcut {
  /// Carbon modifier flags for RegisterEventHotKey.
  var carbonModifiers: Int {
    var flags = 0
    if modifierSet.contains(.command) { flags |= cmdKey }
    if modifierSet.contains(.shift) { flags |= shiftKey }
    if modifierSet.contains(.option) { flags |= optionKey }
    if modifierSet.contains(.control) { flags |= controlKey }
    return flags
  }
}

// MARK: - Window

final class SettingsWindowController {
  private var window: NSWindow?
  private let preferences: Preferences

  init(preferences: Preferences) {
    self.preferences = preferences
  }

  func show() {
    let window = self.window ?? makeWindow()
    self.window = window
    // A menu-bar app must activate itself to take keyboard focus for the recorder.
    NSApp.activate()
    window.center()
    window.makeKeyAndOrderFront(nil)
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
      styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    window.title = "Sidebar Settings"
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: SettingsView(preferences: preferences))
    return window
  }
}

struct SettingsView: View {
  @Bindable var preferences: Preferences

  var body: some View {
    Form {
      Section("Shortcuts") {
        LabeledContent("Copy current URL") {
          HStack {
            ShortcutRecorder(shortcut: $preferences.copyURLShortcut)
            Button("Reset") { preferences.copyURLShortcut = .copyURLDefault }
              .disabled(preferences.copyURLShortcut == .copyURLDefault)
          }
        }
        Text("Works while Chrome is the front app, in Chrome, the sidebar and the ⌘T palette.")
          .font(.caption)
          .foregroundStyle(.secondary)
        LabeledContent("Search tabs and the web", value: "⌘T")
        LabeledContent("Collapse or expand sidebar", value: "⌃⌘S")
      }
    }
    .formStyle(.grouped)
    .frame(width: 420)
    .fixedSize()
  }
}

/// Click, then press the new keys. Escape cancels.
struct ShortcutRecorder: View {
  @Binding var shortcut: Shortcut
  @State private var recording = false
  @State private var monitor: Any?
  @State private var rejected = false

  var body: some View {
    Button(action: toggle) {
      Text(recording ? (rejected ? "Add ⌘, ⌃ or ⌥" : "Type shortcut…") : shortcut.displayString)
        .monospaced()
        .frame(minWidth: 110)
    }
    .onDisappear(perform: stop)
  }

  private func toggle() {
    recording ? stop() : start()
  }

  private func start() {
    recording = true
    rejected = false
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      if event.keyCode == UInt16(kVK_Escape) {
        stop()
        return nil
      }
      let candidate = Shortcut(keyCode: event.keyCode, modifiers: event.routingModifiers)
      guard candidate.isValid else {
        rejected = true
        return nil
      }
      shortcut = candidate
      stop()
      return nil
    }
  }

  private func stop() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    recording = false
  }
}

// MARK: - Toast

/// A short message over Chrome's window, like Arc's "Copied URL".
final class ToastController {
  private var panel: NSPanel?
  private var hideTask: Task<Void, Never>?

  func show(_ message: String, systemImage: String, over area: CGRect?) {
    let panel = self.panel ?? makePanel()
    self.panel = panel
    let host = NSHostingView(rootView: ToastView(message: message, systemImage: systemImage))
    panel.contentView = host
    let size = host.fittingSize
    let area = area ?? NSScreen.main?.visibleFrame ?? .zero
    panel.setFrame(
      CGRect(x: area.midX - size.width / 2, y: area.maxY - 72 - size.height, width: size.width, height: size.height),
      display: true)
    panel.alphaValue = 1
    panel.orderFrontRegardless()

    hideTask?.cancel()
    hideTask = Task { [weak panel] in
      try? await Task.sleep(for: .milliseconds(1200))
      guard !Task.isCancelled, let panel else { return }
      await NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.25
        panel.animator().alphaValue = 0
      }
      guard !Task.isCancelled else { return }
      panel.orderOut(nil)
    }
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    return panel
  }
}

private struct ToastView: View {
  let message: String
  let systemImage: String
  @State private var appeared = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Label {
      Text(message)
    } icon: {
      Image(systemName: systemImage)
        .symbolEffect(.bounce, options: .nonRepeating, value: appeared)
    }
    .font(.system(size: 13, weight: .semibold))
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .glassEffect(.regular, in: Capsule())
    .scaleEffect(appeared || reduceMotion ? 1 : 0.85)
    .offset(y: appeared || reduceMotion ? 0 : -10)
    .opacity(appeared ? 1 : 0)
    .padding(10)
    .onAppear {
      withAnimation(Motion.animation(.spring(response: 0.35, dampingFraction: 0.7), reduceMotion: reduceMotion)) {
        appeared = true
      }
    }
  }
}
