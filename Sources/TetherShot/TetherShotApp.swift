import AppKit
import SwiftUI

@main
struct TetherShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("TetherShot", id: "main") {
            MainWindow(model: model, appDelegate: appDelegate)
                .frame(width: 620, height: 680)
        }
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .newItem) {} }

        MenuBarExtra(
            "TetherShot",
            systemImage: "iphone",
            isInserted: Binding(
                get: { model.showInMenuBar },
                set: { model.setShowInMenuBar($0) }
            )
        ) {
            MenuContent(model: model, showMainWindow: appDelegate.showMainWindow)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Keeps capture, hotkeys, and update checks alive after the main window closes.
/// AppKit is used only for the close/reopen edge that SwiftUI scenes do not expose.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private weak var mainWindow: NSWindow?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    func attach(to window: NSWindow?) {
        guard let window else { return }
        let isNewWindow = mainWindow !== window
        mainWindow = window
        window.delegate = self
        if isNewWindow { showMainWindow() }
    }

    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Resolves the SwiftUI scene's NSWindow once and hands lifecycle control to AppDelegate.
private struct WindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}

extension View {
    func readWindow(_ action: @escaping (NSWindow?) -> Void) -> some View {
        background(WindowReader(onResolve: action).frame(width: 0, height: 0))
    }
}
