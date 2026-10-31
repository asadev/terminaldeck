import SwiftUI
import TerminalDeckNativeCore

/// The ONE device area used by the Simulators page and a session's thin dock.
/// Phone surface, hardware toolbar, screenshot and live Inspect are unchanged.
struct NativeUIGSimulatorDeviceArea: View {
    let model: NativeSimulatorModel
    let selected: DeviceEntry?
    var showingLiveScreen = false
    var working = ""
    var refreshing = false
    var perform: () -> Void
    var refresh: () -> Void
    /// A session's phone panel: "Choose a device" opens its device dropdown (NativeUIGDevicePicker).
    var choose: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 0) {
            if !showingLiveScreen && (!model.problem.isEmpty || !model.said.isEmpty) {
                Text(model.problem.isEmpty ? model.said : model.problem)
                    .font(.callout).foregroundStyle(model.problem.isEmpty ? Color.secondary : Color.red)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 8)
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    @ViewBuilder private var content: some View {
        if showingLiveScreen {
            DeviceOpenView(model: model, showsDeviceBack: false)
        } else if let selected {
            NativeUIGSimulatorStoppedDevice(entry: selected, working: working, action: perform)
        } else if model.list == nil {
            if model.problem.isEmpty { NativePageNote("Loading devices…", busy: true) }
            else {
                NativePageEmpty(symbol: "iphone", title: "Devices could not be read",
                    action: PageEmptyAction(label: "Try again", busy: refreshing, perform: refresh)) {
                    Text("Try again when the app is connected.")
                }
            }
        } else if let list = model.list, !list.available {
            NativePageEmpty(symbol: "iphone", title: "Simulators are not available here",
                action: PageEmptyAction(label: "Try again", busy: refreshing, perform: refresh)) { Text(list.reason) }
        } else if let choose, !(model.list?.devices.isEmpty ?? true) {
            NativePageEmpty(symbol: "iphone", title: "Choose a device",
                action: PageEmptyAction(label: "Choose a device", busy: false, perform: choose)) {
                Text("Pick a phone or simulator to show beside this session.")
            }
            .contentShape(.rect).onTapGesture { choose() }
        } else if !(model.list?.devices.isEmpty ?? true) {
            NativePageEmpty(symbol: "iphone", title: "Choose a device") {
                Text("Pick a phone or simulator from the list, or use its Start or Open button.")
            }
        } else {
            NativePageEmpty(symbol: "iphone", title: "No simulators or phones yet",
                action: PageEmptyAction(label: "Refresh", busy: refreshing, perform: refresh)) {
                Text("Create a simulator in Xcode or an emulator in Android Studio, or connect a supported phone.")
            }
        }
    }
}
