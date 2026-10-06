import SwiftUI
import TerminalDeckNativeCore

/// CloseSessionConfirm.tsx, drawn natively: "Delete this session?" with what it costs,
/// the browser windows that stay behind, and "Don't ask again". The page closes the
/// session (or project, machine, server) itself when told `confirm`.
struct NativeCloseSessionConfirm: View {
    let request: CloseConfirmRequest
    let opening: Int
    let model: AppModel
    @State private var suppress = false
    @State private var busy = false

    var body: some View {
        let warning = request.warning
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
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(warning.headline)
                InfoNote(label: warning.headline, text: warning.detail)
            }
            .padding(.top, 14)
            if let attached = request.attachedLine {
                Text(attached)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
            HStack(spacing: 6) {
                Toggle("Don’t ask again", isOn: $suppress)
                    .toggleStyle(.checkbox)
                InfoNote(label: "Don’t ask again",
                         text: "Sessions go straight away from then on. Settings → General turns this back on.")
            }
            .padding(.top, 14)
            HStack {
                Spacer()
                Button("Keep it open") { model.answerDialog(NativeDialogName.closeConfirm, "cancel") }
                    .keyboardShortcut(.cancelAction)
                Button(busy ? "Deleting…" : request.confirmLabel, role: .destructive) {
                    guard !busy else { return }
                    busy = true
                    // Stays up as "Deleting…" until the page closes it (`open: false`).
                    model.answerDialog(NativeDialogName.closeConfirm, "confirm", argument: ["suppress": suppress], closes: false)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(busy)
            }
            .padding(.top, 20)
        }
        .padding(20)
        .frame(width: 440, alignment: .leading)
        .onChange(of: opening) { suppress = false; busy = false } // a new question: never a stale tick
    }
}
