import AppKit
import SwiftUI

/// The Arc-style frame: the sidebar on the left and a border around Chrome's
/// window, with a transparent hole where Chrome sits. It takes keyboard focus
/// without activating this app, so Chrome stays the frontmost app.
final class SidebarPanel: NSPanel {
  init(model: SidebarModel) {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    // A normal window, kept directly below Chrome's window by the app delegate.
    level = .normal
    collectionBehavior = [.fullScreenNone, .ignoresCycle]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    hidesOnDeactivate = false
    isMovable = false
    animationBehavior = .none

    let host = NSHostingView(rootView: FrameView(model: model))
    // The window's size comes from Chrome's window, never from the SwiftUI content.
    host.sizingOptions = []
    contentView = host
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// The sidebar sliding out over Chrome's left edge while collapsed.
final class PeekPanel: NSPanel {
  init(model: SidebarModel) {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 250, height: 600),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    level = .floating
    collectionBehavior = [.fullScreenNone, .ignoresCycle]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    hidesOnDeactivate = false
    isMovable = false
    animationBehavior = .none

    let host = NSHostingView(rootView: PeekView(model: model))
    host.sizingOptions = []
    contentView = host
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}
