/**
 * Three screens and the rules for which one is showing.
 *
 * The order is a state machine, not a preference: an unpaired phone has nothing
 * to list, and a phone waiting for a human to approve it has nothing to list
 * either — the desktop sends an empty session list with the refusal, and a list
 * screen showing "No sessions" over that would describe the Mac as idle when
 * what is actually happening is that this device is not allowed to see it.
 *
 * The session list is the root of the stack rather than a destination, and a
 * deep link pushes onto it, so backing out of a session opened from the desktop
 * still lands somewhere sensible.
 *
 * ## Why the middle test is `awaitingApproval` and not `phase == .pending`
 *
 * Because they are different facts and the screen needs both. `.pending` means
 * the last attempt reached the Mac and the Mac said "not yet";
 * `awaitingApproval` means this device is unapproved, whether or not the last
 * attempt got anywhere. Routing on the phase alone would drop a phone whose
 * connection is failing into the session list — empty, captioned "No sessions",
 * describing an idle Mac when the truth is that nothing has reached it.
 * `PendingApprovalView` handles both and says which is which.
 */

import SwiftUI

struct RootView: View {
    @Bindable var model: DeckModel

    var body: some View {
        Group {
            if !model.isPaired {
                PairingView(model: model)
            } else if (model.connection.phase == .pending || model.connection.awaitingApproval)
                        && model.sessions.isEmpty {
                PendingApprovalView(model: model)
            } else {
                NavigationStack(path: $model.route) {
                    SessionListView(model: model)
                        .navigationDestination(for: DeckModel.Route.self) { route in
                            switch route {
                            case let .session(id):
                                TerminalScreen(model: model, sessionID: id)
                            }
                        }
                }
            }
        }
        .animation(.default, value: model.isPaired)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }
}

/// The app's own colours. Deliberately few: the terminal supplies its own
/// palette and anything around it competing with that is noise.
enum Theme {
    static let accent = Color(red: 0.20, green: 0.62, blue: 0.95)
    static let background = Color(red: 0.043, green: 0.047, blue: 0.055)
    static let surface = Color(white: 1, opacity: 0.05)
    static let hairline = Color(white: 1, opacity: 0.09)
    static let secondary = Color(white: 1, opacity: 0.55)
    static let faint = Color(white: 1, opacity: 0.35)

    /// The dot on a session row. The vocabulary belongs to the desktop, so an
    /// unknown status gets a neutral colour rather than being dropped or
    /// guessed at.
    static func statusColor(_ status: String) -> Color {
        switch status {
        case "working": return Color(red: 0.30, green: 0.78, blue: 0.42)
        case "waiting", "input": return Color(red: 0.98, green: 0.72, blue: 0.20)
        case "completed": return Color(red: 0.35, green: 0.60, blue: 0.95)
        case "exited": return Color(red: 0.90, green: 0.35, blue: 0.35)
        case "idle": return Color(white: 1, opacity: 0.30)
        default: return Color(white: 1, opacity: 0.30)
        }
    }
}
