import SwiftUI
import TerminalDeckNativeCore

/// "Join a remote session" (src/renderer/components/JoinRemoteDialog.tsx), as a sheet.
///
/// Opened by the page (the command palette's `app.join`) through the native dialog
/// handover; Close answers `close`. Nothing connects yet and the dialog says so first;
/// the two fields still check what is typed, and Join stays disabled on
/// `JoinCode.remoteSessionsAvailable`, not on the form.
struct NativeJoinRemoteDialog: View {
    let close: () -> Void

    @State private var code = ""
    @State private var pin = ""
    @State private var touchedCode = false
    @State private var touchedPin = false
    @FocusState private var focus: Field?

    private enum Field { case code, pin }

    var body: some View {
        let codeNote = JoinCode.codeNote(code, touched: touchedCode)
        let pinNote = JoinCode.pinNote(pin, touched: touchedPin)
        VStack(alignment: .leading, spacing: 0) {
            // Modal header: title and description.
            VStack(alignment: .leading, spacing: 3) {
                Text("Join a remote session").font(.headline)
                Text("Watch or drive a session running on someone else's machine.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 16) {
                // .join-unavailable: the answer to "will this work", before the effort.
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remote sessions are not available yet.")
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    Text("Your code is checked below, but there is nothing to connect to.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1)))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)

                JoinField(label: "Session code", placeholder: "A1B2-C3D4", text: $code,
                          note: codeNote, mono: true, uppercase: true)
                    .focused($focus, equals: .code)
                JoinField(label: "PIN", placeholder: "000000",
                          text: Binding(get: { pin }, set: { pin = JoinCode.normalizePin($0) }),
                          note: pinNote, mono: true, uppercase: false)
                    .focused($focus, equals: .pin)

                VStack(alignment: .leading, spacing: 6) {
                    Button("Join session") {}
                        .disabled(!JoinCode.remoteSessionsAvailable)
                        .help("Remote sessions are not available yet.")
                    Text(JoinCode.status(code: code, pin: pin))
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 2)
            }

            // Modal footer.
            HStack {
                Spacer()
                Button("Close", action: close)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 20)
        }
        .padding(20)
        .frame(width: 460)
        // Blur marks a field touched, as `onBlur` does on the page.
        .onChange(of: focus) { old, _ in
            if old == .code { touchedCode = true }
            if old == .pin { touchedPin = true }
        }
        .onExitCommand(perform: close)
    }
}

/// `.join-field`: label, a filled field, and the note under it — a complaint in red,
/// or the quiet hint in monospaced grey.
private struct JoinField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let note: (text: String, complaint: Bool)
    let mono: Bool
    let uppercase: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.callout.weight(.medium))
            TextField(label, text: $text, prompt: Text(placeholder))
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(.system(.body, design: mono ? .monospaced : .default))
                .tracking(1.8) // letter-spacing: 0.14em — read aloud character by character
                .textCase(uppercase ? .uppercase : nil)
                .autocorrectionDisabled()
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.1)))
                .overlay {
                    if note.complaint {
                        RoundedRectangle(cornerRadius: 7).strokeBorder(Color.red, lineWidth: 1)
                    }
                }
                .accessibilityHint(note.text)
            Text(note.text)
                .font(note.complaint ? .footnote : .system(.footnote, design: .monospaced))
                .foregroundStyle(note.complaint ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tertiary))
                .frame(minHeight: 16, alignment: .topLeading)
        }
    }
}
