import AppKit
import SwiftUI

/// A borderless panel that can take keyboard focus (for the search box) without
/// activating this app, so Chrome stays the frontmost app.
final class SidebarPanel: NSPanel {
  init(model: SidebarModel) {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 260, height: 600),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    hidesOnDeactivate = false
    isMovable = false
    animationBehavior = .none

    let background = NSVisualEffectView()
    background.material = .sidebar
    background.blendingMode = .behindWindow
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = 10
    background.layer?.masksToBounds = true

    let host = NSHostingView(rootView: SidebarView(model: model))
    host.translatesAutoresizingMaskIntoConstraints = false
    background.addSubview(host)
    NSLayoutConstraint.activate([
      host.leadingAnchor.constraint(equalTo: background.leadingAnchor),
      host.trailingAnchor.constraint(equalTo: background.trailingAnchor),
      host.topAnchor.constraint(equalTo: background.topAnchor),
      host.bottomAnchor.constraint(equalTo: background.bottomAnchor),
    ])
    contentView = background
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}
