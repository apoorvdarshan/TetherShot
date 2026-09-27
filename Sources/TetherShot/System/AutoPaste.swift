import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Sends ⌘V to the frontmost app so a hotkey capture lands in whatever field
/// the user was typing in. Posting keyboard events needs Accessibility access.
enum AutoPaste {
    static var hasAccess: Bool { AXIsProcessTrusted() }

    /// Shows the system Accessibility prompt when access is missing. macOS
    /// only presents it until the user answers, so repeated calls are quiet.
    static func requestAccess() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    /// Posts ⌘V. Returns false when Accessibility access is missing.
    static func paste() async -> Bool {
        guard hasAccess else { return false }
        await waitForHotKeyModifiersRelease()
        let source = CGEventSource(stateID: .hidSystemState)
        let key = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
            return false
        }
        // Explicit flags so apps see a plain ⌘V even if a modifier from the
        // hotkey is still down.
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// ⌘⇧7 leaves ⇧ held for a moment, and a held ⇧ turns ⌘V into Paste and
    /// Match Style in many apps. Waits briefly for ⇧, ⌥ and ⌃ to be released.
    private static func waitForHotKeyModifiersRelease() async {
        let stray: CGEventFlags = [.maskShift, .maskAlternate, .maskControl]
        for _ in 0..<50 {
            if CGEventSource.flagsState(.hidSystemState).intersection(stray).isEmpty { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
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
