import SwiftUI
import TerminalDeckNativeCore

/// The command palette's old "join" entry (owner, 13 Nov: no pairing anywhere). It says how devices join now and
/// offers the Devices window; it never makes or asks for anything.
struct NativeJoinRemoteDialog: View {
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(DevicesPage.title).font(.system(size: 20, weight: .semibold))
            Text(DevicesPage.joinBySigningIn).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                NativeSessionButton("Close") { close() }.buttonStyle(.bordered)
                NativeSessionButton("Open Devices") { AppModel.shared.openDevices(); close() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 460)
        .sessionOnExitCommand { close() }
    }
}
