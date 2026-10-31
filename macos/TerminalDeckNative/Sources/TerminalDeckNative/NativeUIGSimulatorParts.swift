import SwiftUI
import TerminalDeckNativeCore

/// The production device row and stopped-device stage, also rendered directly
/// by the isolated review fixture without a model, engine or real device.
struct NativeUIGSimulatorRailRow: View {
    let entry: DeviceEntry
    let selected: Bool
    let working: String
    /// Kept for callers; Start/Open now lives in the row's menu (#108) and the stopped stage.
    var openAction: (() -> Void)? = nil
    /// Session labels for the caption; nil reads the shared attachment projection.
    var sessionLabels: [String]? = nil
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: entry.platform == "ios" ? "iphone" : "smartphone")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(entry.name)
                    NativeFIXESDeviceRowCaption(entry: entry, suppliedLabels: sessionLabels)
                }
                Spacer(minLength: 4)
                if !working.isEmpty || entry.state == "booting" {
                    ProgressView().controlSize(.mini).frame(width: 10)
                } else if entry.available || entry.canBoot {
                    NativeFIXESDeviceRowStatus(entry: entry)
                }
                // Room for the row menu's ⋯ button (NativeFIXESDeviceContextMenu).
                Color.clear.frame(width: 24, height: 1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(selected ? 0.08 : hovered ? 0.05 : 0), in: .rect(cornerRadius: 8))
        .onHover { hovered = $0 }
        .help([entry.name, UIGSimulatorPresentation.description(entry), working.isEmpty ? entry.stateLine : working]
            .filter { !$0.isEmpty }.joined(separator: " · "))
        .accessibilityLabel("\(entry.name), \(UIGSimulatorPresentation.description(entry)), \(working.isEmpty ? entry.stateLine : working)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct NativeUIGSimulatorStoppedDevice: View {
    let entry: DeviceEntry
    let working: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: entry.platform == "ios" ? "iphone" : "smartphone")
                .font(.system(size: 82, weight: .ultraLight))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
                .padding(.bottom, 20)
            Text(entry.name).font(.headline).multilineTextAlignment(.center)
            Text(UIGSimulatorPresentation.description(entry))
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            if !working.isEmpty || entry.state == "booting" {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(working.isEmpty ? "Starting…" : working).font(.callout).foregroundStyle(.secondary)
                }
                .padding(.top, 20)
            } else if let button = UIGSimulatorPresentation.action(entry) {
                Button(button.rawValue, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .nativeUIGGreyControl()
                    .disabled(!UIGSimulatorPresentation.canPerformAction(entry))
                    .padding(.top, 20)
            }
            if !entry.note.isEmpty || (!entry.available && !entry.canBoot && entry.state != "booting") {
                Text(entry.stateLine.isEmpty ? "This device is not available yet. Refresh after reconnecting it." : entry.stateLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
            }
        }
        .frame(maxWidth: 360)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}
