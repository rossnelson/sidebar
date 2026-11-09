import Carbon.HIToolbox

/// One global hotkey through Carbon's RegisterEventHotKey. Works without the
/// Accessibility or Input Monitoring permissions.
final class HotKey {
  private var hotKeyRef: EventHotKeyRef?
  private var handlerRef: EventHandlerRef?
  private let action: () -> Void

  init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
    self.action = action
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let handler: EventHandlerUPP = { _, _, userData in
      guard let userData else { return OSStatus(eventNotHandledErr) }
      let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
      MainActor.assumeIsolated { hotKey.action() }
      return noErr
    }
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    guard InstallEventHandler(GetApplicationEventTarget(), handler, 1, &spec, refcon, &handlerRef) == noErr
    else { return nil }
    let id = EventHotKeyID(signature: OSType(0x5344_4252), id: 1)  // "SDBR"
    guard RegisterEventHotKey(
      UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr
    else { return nil }
  }

  isolated deinit {
    if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    if let handlerRef { RemoveEventHandler(handlerRef) }
  }
}
