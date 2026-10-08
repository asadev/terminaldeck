import SwiftUI
import TerminalDeckNativeCore

/// The production device row and stopped-device stage, also rendered directly
/// by the isolated review fixture without a model, engine or real device.
struct NativeUIGSimulatorRailRow: View {
    let entry: DeviceEntry
    let selected: Bool
    let working: String
    var openAction: (() -> Void)? = nil
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: entry.platform == "ios" ? "iphone" : "smartphone")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .help(entry.name)
                    HStack(spacing: 4) {
                        Text(UIGSimulatorPresentation.kind(entry))
                        Spacer(minLength: 2)
                        Text(UIGSimulatorPresentation.version(entry)).monospacedDigit()
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                if !working.isEmpty || entry.state == "booting" {
                    ProgressView().controlSize(.mini).frame(width: 10)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        if let openAction, let button = UIGSimulatorPresentation.action(entry) {
            HStack {
                Spacer(minLength: 0)
                Button(button.rawValue, action: openAction)
                    .buttonStyle(.bordered).controlSize(.mini).nativeUIGGreyControl()
                    .disabled(!working.isEmpty || entry.state == "booting" || !UIGSimulatorPresentation.canPerformAction(entry))
            }
        }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(selected ? 0.1 : hovered ? 0.06 : 0), in: .rect(cornerRadius: 6))
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
