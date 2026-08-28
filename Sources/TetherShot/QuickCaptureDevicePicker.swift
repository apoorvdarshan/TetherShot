import SwiftUI

/// Shared by the main window and menu-bar menu so both surfaces always edit
/// the same persisted quick-capture target.
struct QuickCaptureDevicePicker: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Picker("Quick Capture Device", selection: Binding(
            get: { model.quickCaptureSelectionID },
            set: { model.setQuickCaptureDevice($0) }
        )) {
            Text("All connected devices").tag("")

            if let preference = model.quickCapturePreference,
               !model.devices.contains(where: { $0.id == preference.id }) {
                Text("\(preference.name) (Not connected)").tag(preference.id)
            }

            ForEach(model.devices) { device in
                Text("\(device.name) · \(device.connectionSummary)").tag(device.id)
            }
        }
        .accessibilityLabel("Quick Capture Device")
    }
}
