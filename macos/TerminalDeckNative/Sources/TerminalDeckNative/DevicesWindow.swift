import SwiftUI
import TerminalDeckNativeCore

/// Devices in its own window, built like Settings: one instance (reopening focuses it), movable
/// outside the main window, opens at Settings' size and remembers its frame. Holds everything the
/// old Devices page had (paired devices, state, pair a device, rename, revoke, device access).
struct DevicesWindow: View {
    static let sceneID = "devices"
    let model: AppModel

    var body: some View {
        MACHINESDevicesScreen(pairOnOpen: model.devicesPairOnOpen)
            .id("devices-\(model.devicesWindowRequest)")
            .frame(minWidth: 680, minHeight: 440)
            .frame(idealWidth: 760, idealHeight: 560)
            .background(NativeSettingsStyle.page)
            .deckWindowAppear()
            .navigationTitle("Devices")
    }
}
