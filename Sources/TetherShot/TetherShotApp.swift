import AppKit
import SwiftUI

@main
struct TetherShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("TetherShot", id: "main") {
            MainWindow(model: model, appDelegate: appDelegate)
                .frame(minWidth: 760, idealWidth: 1040, minHeight: 640, idealHeight: 820)
        }
        .defaultSize(width: 1040, height: 820)
        .windowResizability(.contentMinSize)
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
                .tint(TetherShotTheme.accent)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Keeps capture, hotkeys, and update checks alive after the main window closes.
/// AppKit is used only for the close/reopen edge that SwiftUI scenes do not expose.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private weak var mainWindow: NSWindow?
    private weak var appModel: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppInstallation.relaunchCanonicalCopyIfNeeded() { return }
        AppInstallation.archiveDuplicateUserCopyIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationDidHide(_ notification: Notification) {
        synchronizePreviewVisibility()
    }

    func applicationDidUnhide(_ notification: Notification) {
        synchronizePreviewVisibility()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        synchronizePreviewVisibility(for: sender)
        applyDockPreference()
        return false
    }

    func windowDidMiniaturize(_ notification: Notification) {
        synchronizePreviewVisibility(for: notification.object as? NSWindow)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        synchronizePreviewVisibility(for: notification.object as? NSWindow)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        synchronizePreviewVisibility(for: notification.object as? NSWindow)
    }

    func attach(to window: NSWindow?, model: AppModel) {
        guard let window else { return }
        let isNewWindow = mainWindow !== window
        mainWindow = window
        appModel = model
        model.dockVisibilityDidChange = { [weak self] _ in self?.applyDockPreference() }
        window.delegate = self
        if isNewWindow { showMainWindow() }
    }

    func showMainWindow() {
        applyDockPreference()
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
        synchronizePreviewVisibility()
    }

    private func applyDockPreference() {
        NSApp.setActivationPolicy((appModel?.showInDock ?? true) ? .regular : .accessory)
    }

    private func synchronizePreviewVisibility(for window: NSWindow? = nil) {
        guard let window = window ?? mainWindow else {
            appModel?.setPreviewWindowVisible(false)
            return
        }
        let visible = PreviewActivityPolicy.windowAllowsPreview(
            isVisible: window.isVisible,
            isMiniaturized: window.isMiniaturized,
            occlusionIsVisible: window.occlusionState.contains(.visible),
            appIsHidden: NSApp.isHidden
        )
        appModel?.setPreviewWindowVisible(visible)
    }
}

/// Resolves the SwiftUI scene's NSWindow once and hands lifecycle control to AppDelegate.
private struct WindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowReaderView {
        let view = WindowReaderView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: WindowReaderView, context: Context) {
        nsView.onResolve = onResolve
    }
}

/// Reports only actual window attachment changes. Scheduling work from every
/// `updateNSView` creates a SwiftUI/AppKit invalidation loop on macOS 26.
private final class WindowReaderView: NSView {
    var onResolve: ((NSWindow?) -> Void)?
    private weak var resolvedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window !== resolvedWindow else { return }
        resolvedWindow = window
        onResolve?(window)
    }
}

extension View {
    func readWindow(_ action: @escaping (NSWindow?) -> Void) -> some View {
        background(WindowReader(onResolve: action).frame(width: 0, height: 0))
    }
}
