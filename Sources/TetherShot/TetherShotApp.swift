import SwiftUI
import AppKit

@main
struct TetherShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("TetherShot", systemImage: "iphone") {
            MenuContent(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Forces the app to run as a background agent (belt-and-suspenders with LSUIElement).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
