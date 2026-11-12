import AppKit
import Observation
import SidebarCore
import SwiftUI

/// The tab under the pointer, for the preview card.
@Observable
final class PreviewState {
  var tab: ChromeTab?
  /// The tab's place in its window, 1-based.
  var position = 0
  var tabCount = 0
}

/// A card beside the sidebar with the full title and address of the tab
/// under the pointer. It never takes the mouse: clicks go to Chrome.
final class PreviewController {
  static let size = CGSize(width: 320, height: 200)
  /// Space for the card's shadow.
  static let shadowMargin: CGFloat = 24

  private let state = PreviewState()
  private lazy var panel = makePanel()
  private var hideTask: Task<Void, Never>?

  var isVisible: Bool { panel.isVisible && state.tab != nil }

  /// Shows the card for `tab` next to `row` (top-left origin) in `window`.
  func show(_ tab: ChromeTab, row: CGRect, in window: NSWindow, snapshot: TabSnapshot, appearance: NSAppearance?) {
    hideTask?.cancel()
    let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
    // The card's top lines up with the row's top, beside the sidebar.
    let rowTop = window.frame.maxY - row.minY
    var origin = CGPoint(
      x: window.frame.maxX + 6 - Self.shadowMargin,
      y: rowTop + Self.shadowMargin - Self.size.height - Self.shadowMargin * 2)
    origin.y = max(origin.y, screen.minY - Self.shadowMargin)
    let frame = CGRect(
      origin: origin,
      size: CGSize(width: Self.size.width + Self.shadowMargin * 2, height: Self.size.height + Self.shadowMargin * 2))

    let wasVisible = isVisible
    state.position = (snapshot.tabs.firstIndex(of: tab) ?? 0) + 1
    state.tabCount = snapshot.tabs.count
    panel.appearance = appearance
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if wasVisible && !reduceMotion {
      // Glide from row to row with the content.
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        panel.animator().setFrame(frame, display: true)
      }
    } else {
      panel.setFrame(frame, display: true)
    }
    state.tab = tab
    panel.orderFrontRegardless()
  }

  func hide() {
    guard state.tab != nil else { return }
    state.tab = nil
    hideTask?.cancel()
    hideTask = Task { [weak panel] in
      // Let the card fade out first.
      try? await Task.sleep(for: .milliseconds(200))
      guard !Task.isCancelled else { return }
      panel?.orderOut(nil)
    }
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.animationBehavior = .none
    panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
    let host = NSHostingView(rootView: PreviewCard(state: state))
    host.sizingOptions = []
    panel.contentView = host
    return panel
  }
}

private struct PreviewCard: View {
  let state: PreviewState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let tab = state.tab {
        content(tab)
          .id(tab.id)
          .transition(.opacity)
          .padding(14)
          .frame(width: PreviewController.size.width, alignment: .leading)
          .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
          .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
          .transition(
            reduceMotion
              ? .opacity
              : .scale(scale: 0.94, anchor: .topLeading).combined(with: .opacity).combined(with: .offset(x: -8)))
      }
    }
    .padding(PreviewController.shadowMargin)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .animation(Motion.animation(Motion.press, reduceMotion: reduceMotion), value: state.tab == nil)
    .animation(.easeOut(duration: 0.14), value: state.tab?.id)
  }

  private func content(_ tab: ChromeTab) -> some View {
    let parts = URLComponents(string: tab.url)
    let host = parts?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? ""
    let site = parts?.port.map { "\(host):\($0)" } ?? host
    let rest = [parts?.path, parts?.query.map { "?" + $0 }].compactMap { $0 }.joined()

    return VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 10) {
        Favicon(url: tab.url, size: 24)
          .padding(5)
          .background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        Text(tab.title.isEmpty ? tab.url : tab.title)
          .font(.system(size: 13, weight: .semibold))
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
      }
      VStack(alignment: .leading, spacing: 2) {
        if !site.isEmpty {
          Text(site).font(.system(size: 11.5, weight: .medium))
        }
        if !rest.isEmpty && rest != "/" {
          Text(rest)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
        }
      }
      HStack(spacing: 6) {
        if tab.isLoading {
          Label("Loading", systemImage: "arrow.trianglehead.2.clockwise")
        } else if tab.url.hasPrefix("https://") {
          Label("Secure", systemImage: "lock.fill")
        } else if tab.url.hasPrefix("http://") {
          Label("Not secure", systemImage: "lock.open")
        }
        Spacer(minLength: 0)
        Text("Tab \(state.position) of \(state.tabCount)").monospacedDigit()
      }
      .font(.system(size: 10.5, weight: .medium))
      .foregroundStyle(.secondary)
      .labelStyle(.titleAndIcon)
    }
  }
}
