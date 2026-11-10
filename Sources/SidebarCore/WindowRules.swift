import CoreGraphics

/// The Accessibility attributes that tell a Chrome browser window apart from
/// dialogs, popovers, DevTools and other windows the sidebar must not attach to.
public struct WindowAttributes: Sendable, Equatable {
  public var role: String?
  public var subrole: String?
  public var isModal: Bool
  public var isMinimized: Bool
  public var isFullScreen: Bool
  /// `AXDocument`. Chrome puts the page URL here; DevTools windows carry `devtools://`.
  public var document: String?
  public var size: CGSize
  /// A tabbed browser window has a tab strip. Extension pop-ups (such as a
  /// password manager's login window) and app windows do not.
  public var hasTabStrip: Bool

  public init(
    role: String?, subrole: String?, isModal: Bool = false, isMinimized: Bool = false,
    isFullScreen: Bool = false, document: String? = nil, size: CGSize, hasTabStrip: Bool = true
  ) {
    self.role = role
    self.subrole = subrole
    self.isModal = isModal
    self.isMinimized = isMinimized
    self.isFullScreen = isFullScreen
    self.document = document
    self.size = size
    self.hasTabStrip = hasTabStrip
  }
}

public enum WindowRules {
  static let rejectedSubroles: Set<String> = [
    "AXDialog", "AXSystemDialog", "AXSheet", "AXFloatingWindow", "AXPopover",
  ]
  static let devToolsPrefixes = ["devtools://", "chrome-devtools://"]
  public static let minimumSize = CGSize(width: 400, height: 300)

  public static func isAttachable(_ window: WindowAttributes) -> Bool {
    guard window.role == "AXWindow" else { return false }
    if let subrole = window.subrole, rejectedSubroles.contains(subrole) { return false }
    if window.isModal || window.isMinimized || window.isFullScreen || !window.hasTabStrip { return false }
    if let document = window.document, devToolsPrefixes.contains(where: document.hasPrefix) {
      return false
    }
    return window.size.width >= minimumSize.width && window.size.height >= minimumSize.height
  }
}

/// Where the sidebar goes beside a window. All rects are in Cocoa screen
/// coordinates (origin at the bottom left of the primary screen).
public struct AttachLayout: Sendable, Equatable {
  public var panel: CGRect
  /// A new frame for the browser window when it must move to make room. `nil` means leave it.
  public var windowFrame: CGRect?

  public static let minimumWindowWidth: CGFloat = 500

  public static func compute(window: CGRect, screen: CGRect, sidebarWidth: CGFloat) -> AttachLayout {
    if window.minX - sidebarWidth >= screen.minX {
      return AttachLayout(panel: panel(leftOf: window, width: sidebarWidth), windowFrame: nil)
    }
    // No room on the left: push the window right and shrink it to stay on screen.
    let newMinX = screen.minX + sidebarWidth
    let newMaxX = max(min(window.maxX, screen.maxX), newMinX + minimumWindowWidth)
    let moved = CGRect(x: newMinX, y: window.minY, width: newMaxX - newMinX, height: window.height)
    return AttachLayout(panel: panel(leftOf: moved, width: sidebarWidth), windowFrame: moved)
  }

  private static func panel(leftOf window: CGRect, width: CGFloat) -> CGRect {
    CGRect(x: window.minX - width, y: window.minY, width: width, height: window.height)
  }
}

/// Accessibility uses a top-left origin on the primary screen; Cocoa uses bottom-left.
public enum ScreenCoordinates {
  public static func flip(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
    CGRect(
      x: rect.minX, y: primaryScreenHeight - rect.minY - rect.height,
      width: rect.width, height: rect.height)
  }
}

/// Arc-style frame around Chrome: a sidebar on the left and a margin on the
/// other three sides. Chrome's window sits in the hole. Cocoa coordinates.
public struct FrameLayout: Sendable, Equatable {
  /// Our window: sidebar plus margins plus Chrome.
  public var frame: CGRect
  /// Where Chrome's window sits.
  public var hole: CGRect
  /// A new frame for Chrome when it must move or shrink to fit. `nil` means leave it.
  public var windowFrame: CGRect?

  public static let minimumWindowSize = CGSize(width: 500, height: 300)

  /// Overflow up to this many points counts as fitting. Chrome often settles a
  /// point or two from where it was placed; without slack, each correction
  /// would trigger another one and the window would shrink step by step.
  public static let tolerance: CGFloat = 6

  public static func compute(
    window: CGRect, screen: CGRect, sidebarWidth: CGFloat, margin: CGFloat
  ) -> FrameLayout {
    var target = window
    let slack = tolerance
    // Room for the sidebar on the left.
    if target.minX < screen.minX + sidebarWidth - slack {
      target.origin.x = screen.minX + sidebarWidth
    }
    // Margin on the right, top and bottom.
    if target.maxX > screen.maxX - margin + slack {
      target.size.width = max(screen.maxX - margin - target.minX, minimumWindowSize.width)
    }
    if target.minY < screen.minY + margin - slack {
      target.size.height -= screen.minY + margin - target.minY
      target.origin.y = screen.minY + margin
    }
    if target.maxY > screen.maxY - margin + slack {
      target.size.height -= target.maxY - (screen.maxY - margin)
    }
    target.size.height = max(target.height, minimumWindowSize.height)
    target = CGRect(
      x: target.minX.rounded(), y: target.minY.rounded(),
      width: target.width.rounded(), height: target.height.rounded())

    let frame = CGRect(
      x: target.minX - sidebarWidth, y: target.minY - margin,
      width: sidebarWidth + target.width + margin, height: target.height + margin * 2)
    return FrameLayout(
      frame: frame, hole: target, windowFrame: target.isClose(to: window, within: 0.5) ? nil : target)
  }

  /// The hole in the frame's own coordinates, with a top-left origin (SwiftUI).
  public var holeInFrame: CGRect {
    CGRect(x: hole.minX - frame.minX, y: frame.maxY - hole.maxY, width: hole.width, height: hole.height)
  }
}

extension CGRect {
  /// True when every edge is within `distance` points of the other rect's edge.
  public func isClose(to other: CGRect, within distance: CGFloat) -> Bool {
    abs(minX - other.minX) <= distance && abs(minY - other.minY) <= distance
      && abs(maxX - other.maxX) <= distance && abs(maxY - other.maxY) <= distance
  }
}
