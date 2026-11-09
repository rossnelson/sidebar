import AppKit
import SwiftUI

/// The Arc-style frame: the sidebar on the left and a border around Chrome's
/// window, with a transparent hole where Chrome sits. It never takes keyboard
/// focus, so Chrome keeps every shortcut (⌘W, ⌘1 …) while you click the sidebar.
final class SidebarPanel: NSPanel {
  init(model: SidebarModel) {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    // A normal window, kept directly above Chrome's window by the app delegate,
    // so the border covers Chrome's shadow. Clicks in the transparent hole reach Chrome.
    level = .normal
    collectionBehavior = [.fullScreenNone, .ignoresCycle]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    hidesOnDeactivate = false
    isMovable = false
    animationBehavior = .none

    let host = ClickThroughHostingView(rootView: AnyView(FrameView(model: model)))
    // The window's size comes from Chrome's window, never from the SwiftUI content.
    host.sizingOptions = []
    contentView = host
  }

  override var canBecomeKey: Bool { false }
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

    let host = ClickThroughHostingView(rootView: AnyView(PeekView(model: model)))
    host.sizingOptions = []
    contentView = host
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// A hosting view that acts on the first click. The panels never become key,
/// so every click is a "first" click. Not generic: a generic NSHostingView
/// subclass crashes the Swift 6.3 release compiler (signal 11 in its deinit).
final class ClickThroughHostingView: NSHostingView<AnyView> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
