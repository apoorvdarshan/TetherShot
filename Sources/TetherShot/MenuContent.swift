import SwiftUI

/// The menu shown when the user clicks the TetherShot status-bar icon.
struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.devices.isEmpty {
            Text("No iPhone detected over USB")
        } else {
            ForEach(model.devices) { device in
                Button("📸  \(device.name) (\(device.connection.rawValue))") {
                    model.capture(device)
                }
            }
            if model.devices.count > 1 {
                Button("📸  Screenshot All") { model.captureAll() }
            }
        }

        Divider()

        Button("Refresh Devices") { model.refreshDevices() }

        Divider()

        Text("Saving to: \(model.destinationFolder.lastPathComponent)")
        Button("Choose Folder…") { model.chooseFolder() }
        Button("Open Folder") { model.openFolder() }

        if !model.lastStatus.isEmpty {
            Divider()
            Text(model.lastStatus)
        }

        Divider()

        Button("Quit TetherShot") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
