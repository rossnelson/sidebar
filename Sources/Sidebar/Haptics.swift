import AppKit

/// Light trackpad feedback, for a drop target and a finished swipe.
enum Haptics {
  /// Something snapped into place under the pointer.
  static func snap() {
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
  }

  /// A step that changed something: a drop, a space change.
  static func step() {
    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
  }
}
