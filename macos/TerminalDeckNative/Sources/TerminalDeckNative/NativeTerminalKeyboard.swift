import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// 28 Oct (bug B): where the Mac's keyboard is, as far as the session terminals need to know. A phone screen (a
/// device panel beside a session) tells it when it takes or lets go of the keyboard; a terminal on screen then says
/// "Typing goes to the phone" while the phone has it (`TerminalKeyboardNotice`), and his choice of a session moves
/// the keyboard back to that session's terminal (`TerminalKeyboardChoice`, read by `DeviceKeyboardHold`).
@MainActor
enum NativeTerminalKeyboard {
    static let holderChanged = Notification.Name("dev.terminaldeck.keyboard-holder-changed")
    private static var choice = TerminalKeyboardChoice()
    /// His choice of a session in the session list, the tab strip or with ⌘-number (`NativeTerminalSessions.chosenHere`).
    static func noteChoice() { choice.chose(at: ProcessInfo.processInfo.systemUptime) }
    /// A terminal asking for the keyboard now does so because he just chose its session.
    static func choiceMoves(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool { choice.moves(now: now) }
    /// The keyboard of `window` is held by a phone screen.
    static func phoneHolds(_ window: NSWindow?) -> Bool { window?.firstResponder is DeviceScreenNSView }
    /// A phone screen took or let go of the keyboard.
    static func holderMoved() { NotificationCenter.default.post(name: holderChanged, object: nil) }
}

/// Over the bottom of a terminal while the phone screen beside it has the keyboard: one click types here instead.
struct NativeTerminalKeyboardElsewhere: View {
    let session: NativeTerminalSession

    var body: some View {
        Button { session.typeHere() } label: {
            HStack(spacing: 6) {
                Image(systemName: "keyboard")
                Text("Typing goes to the phone beside this session, not here.")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text("Type here").fontWeight(.semibold)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to type in this session. Click the phone to type into the phone again.")
        .accessibilityLabel("Typing goes to the phone beside this session. Type here instead.")
    }
}
