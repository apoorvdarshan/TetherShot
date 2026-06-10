import Carbon.HIToolbox
import AppKit

/// A single system-wide hotkey registered through the Carbon Hot Key API.
///
/// Carbon's `RegisterEventHotKey` works globally without the Accessibility /
/// Input-Monitoring permission that `NSEvent.addGlobalMonitorForEvents` requires,
/// which makes it the right fit for a background menu-bar agent.
final class HotKey {
    /// ⌘⇧7 — the default quick-capture shortcut (kVK_ANSI_7 = 26).
    static let defaultKeyCode: UInt32 = 26
    static let defaultModifiers: UInt32 = UInt32(cmdKey | shiftKey)
    static var defaultDisplay: String { "⌘⇧7" }

    private let action: () -> Void
    private let hotKeyID = EventHotKeyID(signature: 0x54_53_48_54 /* 'TSHT' */, id: 1)
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// Invoked by the C callback. Hops to the main actor for the real work.
    func fire() { action() }

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var handlerRef: EventHandlerRef?
        guard InstallEventHandler(GetApplicationEventTarget(), tetherShotHotKeyCallback,
                                  1, &eventType, selfPtr, &handlerRef) == noErr else {
            return nil
        }
        handler = handlerRef

        var hotKeyRef: EventHotKeyRef?
        guard RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                  GetApplicationEventTarget(), 0, &hotKeyRef) == noErr else {
            return nil
        }
        ref = hotKeyRef
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

/// C-compatible trampoline (no captures) → forwards to the owning HotKey.
private func tetherShotHotKeyCallback(_ next: EventHandlerCallRef?,
                                      _ event: EventRef?,
                                      _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().fire()
    return noErr
}
