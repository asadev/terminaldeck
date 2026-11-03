import SwiftUI
import TerminalDeckNativeCore

/// SwitchAccountConfirm.tsx, drawn natively: "Switch to <account>?", from → to with the
/// conversation tag and its ⓘ note, a refusal or a problem in plain words, and Cancel /
/// "Switch at my next message" / "Switch now". The page does the switching and keeps
/// this up (busy, a problem) until it is done.
struct NativeSwitchAccountConfirm: View {
    let request: SwitchAccountRequest
    let model: AppModel
    /// The app's own switch (the account chip, 12 Oct) says its offer and takes the answer itself; the page's
    /// switch leaves both nil and is answered through the page as before.
    var notice: String? = nil
    /// Only with the offer, only while the agent is busy (AccountSwitchWords.warning).
    var warning: String? = nil
    var answer: ((String) -> Void)? = nil

    /// 12 Oct: a session that started before account switching was ready cannot switch in place; it is started
    /// again on the account, carrying on the same conversation. The page's fields have no place for that, so the
    /// offer the backend kept for this window's last plan is read here and said in plain words, with Switch
    /// (Asad: to the person this is always a switch, never a restart).
    private var offerText: String? {
        guard request.planned, request.refusal == nil else { return nil }
        if answer != nil { return notice }
        return SwitchAccountRestartOffer.current.map { SwitchAccountRestartOffer.sentence(accountName: request.toName, carriesOn: $0.carriesOn) }
    }
    private func reply(_ action: String, closes: Bool = true) {
        if let answer { answer(action) } else { model.answerDialog(NativeDialogName.switchAccount, action, closes: closes) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(request.heading)
                .font(.headline)
            if !request.title.isEmpty {
                Text(request.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.top, 4)
            }
            Group {
                if let pending = request.pendingLine {
                    Text(pending).foregroundStyle(.secondary)
                }
                if let refusal = request.refusal {
                    Text(refusal)
                        .accessibilityAddTraits(.isStaticText)
                }
                if let offerText {
                    Text(offerText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isStaticText)
                    if let warning {
                        Text(warning)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 6)
                    }
                } else if request.canSwitch {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(request.fromName) → \(request.toName)")
                        if let tag = request.tag {
                            Text(tag)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(.quaternary))
                        }
                        InfoNote(label: "What switching does", text: request.note)
                    }
                }
                if let problem = request.problem {
                    (Text(problem).foregroundStyle(.red)
                        + Text(" This session is still running as it was.").foregroundStyle(.secondary))
                }
            }
            .padding(.top, 14)
            HStack {
                Spacer()
                Button(request.dismissLabel) { reply("cancel") }
                    .keyboardShortcut(.cancelAction)
                if offerText == nil && request.offersSwitch && request.canDefer {
                    Button("Switch at my next message") {
                        reply("defer", closes: false)
                    }
                    .disabled(request.busy)
                }
                if request.offersSwitch {
                    Button(offerText == nil ? request.confirmLabel
                           : request.busy ? SwitchAccountRestartOffer.busyLabel : SwitchAccountRestartOffer.confirmLabel) {
                        reply("confirm", closes: false)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(request.busy)
                }
            }
            .padding(.top, 20)
        }
        .padding(20)
        .frame(width: 460, alignment: .leading)
    }
}
