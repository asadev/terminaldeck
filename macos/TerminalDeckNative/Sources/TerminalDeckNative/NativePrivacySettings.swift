import AppKit
import SwiftUI
import TerminalDeckBackend

struct NativePrivacySettings: View {
    @State private var showCleanup = false
    @State private var problem: String?
    init(showCleanup: Bool = false) { _showCleanup = State(initialValue: showCleanup) }
    var body: some View {
        NativeSettingsFormFrame(title: "Privacy") {
            Form {
                Section("Your Mac’s permissions") {
                    Text(BackendPrivacyIdentity.explanation).foregroundStyle(.secondary)
                    ForEach(BackendPrivacyIdentity.panes) { pane in
                        HStack {
                            Text(pane.title)
                            Spacer()
                            Button("Open settings") {
                                problem = NSWorkspace.shared.open(pane.url) ? nil : "macOS could not open that privacy list. Open System Settings > Privacy & Security."
                            }.accessibilityLabel("Open " + pane.title)
                        }
                    }
                }
                Section("Older versions") {
                    Text("Lists may still show TerminalDeckNativeHelper from older versions. Sessions now use Terminal Deck’s entry, so those can go.").foregroundStyle(.secondary)
                    Button("Remove old Terminal Deck entries") { showCleanup.toggle() }
                    if showCleanup { NativePrivacyCleanupSteps() }
                }
                if let problem { Section { Text(problem).foregroundStyle(.red) } }
            }.formStyle(.grouped)
        }
    }
}

struct NativePrivacyCleanupSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(BackendPrivacyIdentity.cleanupSteps.enumerated()), id: \.offset) { index, step in
                Text("\(index + 1). " + step).fixedSize(horizontal: false, vertical: true)
            }
            Text("No permissions have been reset. Old bare helpers need the minus button; a reset would not reliably remove their rows.")
                .font(.callout).foregroundStyle(.secondary)
        }.textSelection(.enabled)
    }
}
