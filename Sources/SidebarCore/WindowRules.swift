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

  public init(
    role: String?, subrole: String?, isModal: Bool = false, isMinimized: Bool = false,
    isFullScreen: Bool = false, document: String? = nil, size: CGSize
  ) {
    self.role = role
    self.subrole = subrole
    self.isModal = isModal
    self.isMinimized = isMinimized
    self.isFullScreen = isFullScreen
    self.document = document
    self.size = size
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
    if window.isModal || window.isMinimized || window.isFullScreen { return false }
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
