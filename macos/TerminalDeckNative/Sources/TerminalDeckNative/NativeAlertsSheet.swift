import SwiftUI
import TerminalDeckNativeCore

/// AlertsWindow + AlertsPanel (AlertsPanel.tsx), drawn natively: the summary and
/// "Check again", alerts grouped worst-first with their actions, and the same empty
/// states. "Done" closes it. The page acts on every press (rescan, an alert's action);
/// approving a device happens right here, in lane V's NativePendingApproval (the
/// web's PendingApproval inside AlertsWindow, titled "Let a device in").
struct NativeAlertsSheet: View {
    let request: AlertsRequest
    let model: AppModel
    @State private var approving: String?

    private func answer(_ action: String, _ argument: [String: Any]? = nil, closes: Bool = false) {
        model.answerDialog(NativeDialogName.alerts, action, argument: argument, closes: closes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(approving == nil ? "Alerts" : "Let a device in")
                .font(.headline)
                .padding([.horizontal, .top], 20)
            ScrollView {
                Group {
                    if let device = approving, !request.noProject {
                        // An NSOpenPanel is its own window over the sheet, so nothing has to step aside (onPicking).
                        NativePendingApproval(deviceId: device, onDone: { approving = nil })
                    } else {
                        content
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(20)
            }
            .frame(minHeight: 320)
            if approving == nil {
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { answer("close", closes: true) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(16)
            }
        }
        .frame(width: 640)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project alerts")
    }

    @ViewBuilder private var content: some View {
        if request.noProject {
            NativePageEmpty(symbol: "bell", title: "No project open") {
                Text("Alerts are about the project you have open — what is blocked in it, what is filling up, what it is waiting on you for. Open one and this will have something to say.")
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                if !request.quiet {
                    HStack(alignment: .firstTextBaseline) {
                        Text(request.headline)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(color(request.shown?.worst))
                        Spacer()
                        Button(request.busy ? "Checking…" : "Check again") { answer("rescan") }
                            .disabled(request.busy || !request.available)
                    }
                }
                if !request.available {
                    NativePageEmpty(symbol: "bell", title: "Alerts are not available here") {
                        Text("Alerts are not connected to the main process yet.")
                    }
                } else if request.quiet {
                    NativePageEmpty(symbol: "bell", title: "Nothing needs your attention",
                                    action: PageEmptyAction(label: request.busy ? "Checking…" : "Check again", busy: request.busy) { answer("rescan") }) {
                        Text("Context is healthy, nothing is blocked, and the tools this project uses are installed.")
                    }
                } else if let shown = request.shown {
                    let groups = shown.groups
                    ForEach(groups, id: \.severity) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            if groups.count > 1 {
                                Text(group.severity.heading)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(group.alerts) { alert in row(alert) }
                        }
                    }
                }
            }
        }
    }

    private func row(_ alert: ProjectAlert) -> some View {
        rowBody(alert).driveAnchor(DriveAnchor.alert(alertId: alert.id).id)
    }

    private func rowBody(_ alert: ProjectAlert) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(color(alert.severity))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(alert.title).font(.body.weight(.medium))
                Text(alert.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let action = alert.action, action.kind != "approve-device" || action.target != nil {
                    Button(action.label) {
                        if action.kind == "approve-device", let device = action.target {
                            approving = device
                        } else {
                            answer("action", ["id": alert.id], closes: true)
                        }
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.5)))
    }

    private func color(_ severity: AlertSeverity?) -> Color {
        switch severity {
        case .critical: .red
        case .warning: .orange
        case .info: .blue
        case nil: .secondary
        }
    }
}
