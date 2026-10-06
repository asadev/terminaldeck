import SwiftUI
import TerminalDeckNativeCore

/// SwitchAccountConfirm.tsx, drawn natively: "Switch to <account>?", from → to with the
/// conversation tag and its ⓘ note, a refusal or a problem in plain words, and Cancel /
/// "Switch at my next message" / "Switch now". The page does the switching and keeps
/// this up (busy, a problem) until it is done.
struct NativeSwitchAccountConfirm: View {
    let request: SwitchAccountRequest
    let model: AppModel

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
                if request.canSwitch {
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
                Button(request.dismissLabel) { model.answerDialog(NativeDialogName.switchAccount, "cancel") }
                    .keyboardShortcut(.cancelAction)
                if request.offersSwitch && request.canDefer {
                    Button("Switch at my next message") {
                        model.answerDialog(NativeDialogName.switchAccount, "defer", closes: false)
                    }
                    .disabled(request.busy)
                }
                if request.offersSwitch {
                    Button(request.confirmLabel) {
                        model.answerDialog(NativeDialogName.switchAccount, "confirm", closes: false)
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
