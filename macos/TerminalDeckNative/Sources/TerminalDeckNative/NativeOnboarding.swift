import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// components/Onboarding.tsx, drawn natively over the whole window: the welcome
/// line, the coding agents (you need one), the optional tools, the sign-in
/// callout, and Open a project / Re-check / Skip for now. The page decides when
/// it shows (only when no agent can run) and does both acts; this asks
/// `prereq:check` itself, as the page's screen did.
struct NativeOnboarding: View {
    let appName: String
    let model: AppModel

    @State private var prereq: CodingAIPrerequisites?
    @State private var checking = true

    var body: some View {
        let split = Onboarding.split(prereq?.tools ?? [])
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Onboarding.title(appName)).font(.largeTitle.weight(.semibold))
                    Text(Onboarding.lede(appName)).font(.title3).foregroundStyle(.secondary)
                }

                section(Onboarding.agentsHeading, note: Onboarding.agentsNote) {
                    if checking { Text(Onboarding.checking).font(.callout).foregroundStyle(.secondary) }
                    ForEach(split.agents) { tool in row(tool, line: Onboarding.agentLine(tool), version: true) }
                }

                section(Onboarding.extrasHeading, note: Onboarding.extrasNote) {
                    ForEach(split.extras) { tool in row(tool, line: tool.purpose, version: false) }
                }

                if prereq?.needsLogin == true {
                    Label(Onboarding.needsLogin, systemImage: "person.badge.key")
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.1)))
                }

                HStack(spacing: 10) {
                    Button(Onboarding.openProject) { model.answerDialog(NativeDialogName.onboarding, "open-project", closes: false) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    Button(Onboarding.recheck) { Task { await check() } }
                        .disabled(checking)
                    Button(Onboarding.skip) { model.answerDialog(NativeDialogName.onboarding, "continue") }
                }
                .controlSize(.large)
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
        .task { await check() }
    }

    private func section(_ title: String, note: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3.weight(.semibold))
            Text(note).font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 0) { rows() }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.background.secondary))
        }
    }

    private func row(_ tool: CodingAITool, line: String, version: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Circle().fill(dot(tool.state)).frame(width: 8, height: 8).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.label).font(.body.weight(.medium))
                    if version, let label = Onboarding.versionLabel(tool) {
                        Text(label)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(label == CodingAITool.noVersion ? .orange : .secondary)
                            .help(label == CodingAITool.noVersion ? CodingAITool.noVersionHint : "")
                    }
                }
                Text(line).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(Onboarding.stateLabel(tool.state)).font(.callout).foregroundStyle(.secondary)
            if version, tool.state == .missing, let link = tool.url, let url = URL(string: link) {
                Button(Onboarding.getIt) { NSWorkspace.shared.open(url) }.buttonStyle(.link)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func dot(_ state: CodingAITool.State) -> Color {
        switch state {
        case .ready: return .green
        case .installedNotAuthed: return .orange
        case .missing: return .red
        case .unknown: return .gray
        }
    }

    private func check() async {
        checking = true
        defer { checking = false }
        if let answer = try? await EngineBridge.shared.invoke("prereq:check") {
            prereq = CodingAIPrerequisites.parse(CodingAIJSON(answer))
        }
    }
}
