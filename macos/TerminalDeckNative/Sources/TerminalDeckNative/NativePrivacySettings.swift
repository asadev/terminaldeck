import AppKit
import SwiftUI
import TerminalDeckBackend

/// Settings → Privacy (owner, 15 Nov; DESIGN.md section 4, item 57): it stays in the app (these are this Mac's own
/// permissions; a web page cannot read or open them). One group "This Mac's permissions": per row the name, the real
/// state where the Mac lets the app read it ("Allowed" / "Not allowed" in orange), and Open. The explanation is in ONE
/// info button beside the group title. "Remove old Terminal Deck entries" moved to Advanced.
struct NativePrivacySettings: View {
    @State private var problem: String?
    @State private var states: [String: Bool] = [:]
    /// Kept for old callers and pictures (the clean-up now lives in Advanced).
    init(showCleanup: Bool = false) {}
    var body: some View {
        DeckSettingsScaffold(title: "Privacy") {
            DeckSettingsGroup("This Mac's permissions", info: BackendPrivacyIdentity.explanation) {
                ForEach(BackendPrivacyIdentity.panes) { pane in
                    let allowed = states[pane.id]
                    DeckSettingsRow(pane.title, state: allowed.map { $0 ? "Allowed" : "Not allowed" },
                                    stateColor: allowed == false ? DeckTokens.warn : .secondary) {
                        Button("Open") {
                            problem = NSWorkspace.shared.open(pane.url) ? nil : "macOS could not open that privacy list. Open System Settings > Privacy & Security."
                        }
                        .controlSize(.small)
                        .accessibilityLabel("Open " + pane.title)
                    }
                }
                if let problem { DeckSettingsProblem(text: problem) }
            }
        }
        .task { states = NativePrivacyStates.read() }
    }
}

/// The permissions whose state macOS lets an app read without asking: screen recording and accessibility. The others
/// show no state (never a guess).
enum NativePrivacyStates {
    @MainActor static func read() -> [String: Bool] {
        ["screen": CGPreflightScreenCaptureAccess(), "accessibility": AXIsProcessTrusted()]
    }
}

struct NativePrivacyCleanupSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(BackendPrivacyIdentity.cleanupSteps.enumerated()), id: \.offset) { index, step in
                Text("\(index + 1). " + step).fixedSize(horizontal: false, vertical: true)
            }
        }.textSelection(.enabled)
    }
}
