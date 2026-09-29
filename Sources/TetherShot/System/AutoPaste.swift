import AppKit
import ApplicationServices
import Carbon.HIToolbox

@MainActor
enum AutoPaste {
    enum Outcome: Equatable { case posted, needsAccess, skipped }

    struct Destination {
        let pid: pid_t
        let focusedElement: AXUIElement?
    }

    static var hasAccess: Bool { AXIsProcessTrusted() }
    private static var requestedAccess = false

    static func requestAccess() {
        guard !requestedAccess else { return }
        requestedAccess = true
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    /// Capture focus at the hotkey, before discovery or screenshot work awaits.
    static func destination() -> Destination? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return Destination(pid: app.processIdentifier, focusedElement: focusedElement(pid: app.processIdentifier))
    }

    private static func focusedElement(pid: pid_t) -> AXUIElement? {
        guard hasAccess else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func paste(destination: Destination, clipboardChangeCount: Int) async -> Outcome {
        await pasteValidated(
            access: { hasAccess },
            waitForRelease: { await waitForHotKeyModifiersRelease() },
            contextMatches: {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == destination.pid,
                      NSPasteboard.general.changeCount == clipboardChangeCount,
                      let original = destination.focusedElement,
                      let current = focusedElement(pid: destination.pid) else { return false }
                return CFEqual(original, current)
            },
            post: {
                let source = CGEventSource(stateID: .hidSystemState)
                let key = CGKeyCode(kVK_ANSI_V)
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
                down.flags = .maskCommand
                up.flags = .maskCommand
                // Target the original process even if another app activates
                // between the final check and delivery of these events.
                down.postToPid(destination.pid)
                up.postToPid(destination.pid)
                return true
            }
        )
    }

    /// Keep the asynchronous boundary testable without posting real keystrokes.
    static func pasteValidated(
        access: () -> Bool,
        waitForRelease: () async -> Bool,
        contextMatches: () -> Bool,
        post: () -> Bool
    ) async -> Outcome {
        guard access() else { return .needsAccess }
        guard contextMatches(), await waitForRelease(), !Task.isCancelled else { return .skipped }
        guard access() else { return .needsAccess }
        guard contextMatches() else { return .skipped }
        return post() ? .posted : .skipped
    }

    private static func waitForHotKeyModifiersRelease() async -> Bool {
        let stray: CGEventFlags = [.maskShift, .maskAlternate, .maskControl]
        for _ in 0..<50 {
            if Task.isCancelled { return false }
            if CGEventSource.flagsState(.hidSystemState).intersection(stray).isEmpty { return true }
            do { try await Task.sleep(nanoseconds: 10_000_000) } catch { return false }
        }
        return false
    }
}

/// Decides whether a finished capture should be pasted.
enum AutoPastePolicy {
    static func shouldPaste(
        enabled: Bool,
        copiedToClipboard: Bool,
        fromHotKey: Bool,
        frontmostIsTetherShot: Bool
    ) -> Bool {
        // Captures started from TetherShot's own window would paste into
        // TetherShot itself, so only hotkey captures paste.
        enabled && copiedToClipboard && fromHotKey && !frontmostIsTetherShot
    }
}
