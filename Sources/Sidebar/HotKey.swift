import Carbon.HIToolbox

/// A global hotkey through Carbon's RegisterEventHotKey. Needs no Accessibility
/// or Input Monitoring permission. While registered, the key does not reach
/// other apps, so turn it off (`isEnabled = false`) when it should not apply.
final class HotKey {
  private static var registry: [UInt32: HotKey] = [:]
  private static var nextID: UInt32 = 1
  private static var handlerInstalled = false

  private let id: UInt32
  private let keyCode: UInt32
  private let modifiers: UInt32
  private let action: () -> Void
  private var ref: EventHotKeyRef?

  init(keyCode: Int, modifiers: Int, enabled: Bool = true, action: @escaping () -> Void) {
    id = Self.nextID
    Self.nextID += 1
    self.keyCode = UInt32(keyCode)
    self.modifiers = UInt32(modifiers)
    self.action = action
    Self.installHandler()
    Self.registry[id] = self
    isEnabled = enabled
  }

  var isEnabled: Bool {
    get { ref != nil }
    set {
      if newValue, ref == nil {
        let hotKeyID = EventHotKeyID(signature: OSType(0x5344_4252), id: id)  // "SDBR"
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
      } else if !newValue, let ref {
        UnregisterEventHotKey(ref)
        self.ref = nil
      }
    }
  }

  isolated deinit {
    isEnabled = false
    Self.registry[id] = nil
  }

  /// One handler for every hotkey; it dispatches by the hotkey's ID.
  private static func installHandler() {
    guard !handlerInstalled else { return }
    handlerInstalled = true
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let handler: EventHandlerUPP = { _, event, _ in
      var hotKeyID = EventHotKeyID()
      let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
      guard status == noErr else { return status }
      MainActor.assumeIsolated { HotKey.registry[hotKeyID.id]?.action() }
      return noErr
    }
    InstallEventHandler(GetApplicationEventTarget(), handler, 1, &spec, nil, nil)
  }
}
