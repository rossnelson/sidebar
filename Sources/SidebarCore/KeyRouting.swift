/// Decides which keys pressed in the Cmd+T palette belong to Chrome.
///
/// The palette has a text field, so it keeps typing, text editing and its own
/// keys. Other Command shortcuts, and Control-Tab, are Chrome's: the palette
/// closes and passes them on, so ⌘W, ⌘⇧T, ⌘1–9 and the rest work everywhere.
public enum KeyRouting {
  public struct Modifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = Modifiers(rawValue: 1)
    public static let shift = Modifiers(rawValue: 2)
    public static let option = Modifiers(rawValue: 4)
    public static let control = Modifiers(rawValue: 8)
  }

  /// macOS virtual key codes used here.
  public enum Key {
    public static let a: UInt16 = 0, z: UInt16 = 6, x: UInt16 = 7, c: UInt16 = 8, v: UInt16 = 9
    public static let h: UInt16 = 4, q: UInt16 = 12, w: UInt16 = 13, t: UInt16 = 17
    public static let comma: UInt16 = 43, m: UInt16 = 46, tab: UInt16 = 48, delete: UInt16 = 51
    public static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
  }

  /// Command keys the palette keeps: its own ⌘T, text editing, and app keys
  /// (quit, hide, minimize, settings) that must never reach Chrome by accident.
  static let paletteCommandKeys: Set<UInt16> = [
    Key.t, Key.a, Key.c, Key.v, Key.x, Key.z, Key.delete, Key.up, Key.down,
    Key.q, Key.h, Key.m, Key.comma,
  ]

  public static func forwardsToChrome(keyCode: UInt16, modifiers: Modifiers) -> Bool {
    if modifiers.contains(.control) {
      // ⌃Tab and ⌃⇧Tab switch tabs; other Control keys are text editing (⌃A, ⌃E, ⌃K …).
      return keyCode == Key.tab && !modifiers.contains(.command)
    }
    guard modifiers.contains(.command) else { return false }
    if keyCode == Key.t {
      // ⌘T is the palette's own (a blank tab); ⌘⇧T reopens a closed tab in Chrome.
      return modifiers.contains(.shift)
    }
    if keyCode == Key.left || keyCode == Key.right {
      // ⌘⌥←/→ switch tabs; ⌘←/→ move the text cursor.
      return modifiers.contains(.option)
    }
    return !paletteCommandKeys.contains(keyCode)
  }
}
