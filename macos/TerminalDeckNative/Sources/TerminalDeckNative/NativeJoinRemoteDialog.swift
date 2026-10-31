import SwiftUI

/// The command palette uses the same one-step device pairing sheet as Devices.
/// Session-code/PIN fields are gone: the native machines:pair path really pairs a computer.
struct NativeJoinRemoteDialog: View {
    let close: () -> Void
    @State private var model = RemoteSectionModel()
    @State private var machines = MachinesHalfModel()

    var body: some View {
        MACHINESDevicesPairSheet(model: model, machines: machines, fixture: false, typeCodeOnOpen: true, close: close)
            .task {
                async let remote: Void = model.start()
                async let reach: Void = machines.start()
                _ = await (remote, reach)
            }
            .onDisappear { model.stop(); machines.stop() }
    }
}
