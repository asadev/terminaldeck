import SwiftUI

/// Kept separate so the exact control on the history card can be rendered
/// without opening a real chat or connecting to the session helper.
struct AGTTeamChatRecoveryControl: View {
    let pending: Bool
    let resume: () -> Void
    var body: some View {
        Button(pending ? "Resuming…" : "Resume", action: resume)
            .controlSize(.small).disabled(pending)
            .help("Resume the saved AI conversation")
    }
}
