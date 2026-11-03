import Observation
import SwiftUI

/// Selection within the existing server page. This is not a sidebar destination.
enum NativeServerControlMode: String, CaseIterable, Identifiable, Sendable {
    case apps
    case advanced

    var id: Self { self }
    var title: String { self == .apps ? "Apps" : "Advanced" }
}

@MainActor
@Observable
final class NativeServerControlController {
    /// CONTRACT-docker.md: "local" is This Mac; otherwise a saved server ID.
    let target: String
    let name: String
    private(set) var mode: NativeServerControlMode

    init(target: String, name: String) {
        self.target = target
        self.name = name
        mode = target == "local" ? .advanced : .apps
    }

    var isThisMac: Bool { target == "local" }

    func select(_ next: NativeServerControlMode) {
        guard !isThisMac || next == .advanced else { return }
        mode = next
    }
}

/// Mount under NativeServerPage's existing header and host overview. Child
/// factories are supplied by DKA as each UI owner becomes available. Missing
/// factories report unavailable rather than suggesting the server has no apps.
///
/// Only the selected child is mounted: leaving Advanced removes its log/stat/
/// terminal views so their existing onDisappear hooks can release their streams.
struct NativeServerControlHost: View {
    typealias Child = @MainActor (String) -> AnyView

    @Bindable var controller: NativeServerControlController
    var apps: Child?
    var advanced: Child?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if controller.isThisMac {
                // A single available mode is an answer, not a picker (SettingsKit).
                Text("Advanced")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
            } else {
                // Same native view selector as NativeTasksMyWork; no custom tint.
                Picker("Server view", selection: Binding(
                    get: { controller.mode },
                    set: { controller.select($0) })) {
                    ForEach(NativeServerControlMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .nativeUIGGreyControl()
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("server-control-view")
            }

            Group {
                switch controller.mode {
                case .apps:
                    if let apps {
                        apps(controller.target)
                    } else {
                        NativePageEmpty(symbol: "square.grid.2x2", title: "Apps are unavailable") {
                            NativeSettingsProse(text: "This version cannot manage apps on this server yet.")
                        }
                        .frame(minHeight: 320)
                    }
                case .advanced:
                    if let advanced {
                        advanced(controller.target)
                    } else {
                        NativePageEmpty(symbol: "server.rack", title: "Advanced controls are unavailable") {
                            NativeSettingsProse(text: controller.isThisMac
                                ? "This version cannot manage local resources yet."
                                : "This version cannot manage these server resources yet.")
                        }
                        .frame(minHeight: 320)
                    }
                }
            }
            // A target or mode change must dispose of the previous child's state.
            .id(controller.target + "/" + controller.mode.rawValue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
