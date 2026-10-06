import SwiftUI
import TerminalDeckNativeCore

// Hoot's permission question, drawn in Swift (lane B) — renderer/copilot/CopilotConsent.tsx.
// The page keeps the queue (`useConsent`: the engine's requests, the settled pushes,
// attach and answer) and hands over the question on screen with its words made;
// this sheet counts down and answers "allow" or "refuse" with the question's id.
// Escape answers "cancel", which the page takes as Refuse, as the web dialog's close did.

struct NativeCopilotConsent: View {
    let request: CopilotConsentRequest
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.heading).font(.title3.weight(.semibold))
                Text(request.asker)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 12) {
                Text(request.summary)
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !request.rows.isEmpty { arguments }
                HStack(spacing: 8) {
                    Text(request.tier.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .background(Capsule().fill(Color.orange.opacity(0.18)))
                    Text(request.tool)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = CopilotConsentWords.secondsLeft(expiresAt: request.expiresAt,
                                                                  now: context.date.timeIntervalSince1970 * 1000)
                    let urgent = CopilotConsentWords.urgent(seconds)
                    Text(CopilotConsentWords.timeout(seconds))
                        .font(.footnote.weight(urgent ? .medium : .regular))
                        .foregroundStyle(urgent ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                }
                if let waiting = CopilotConsentWords.waiting(request.waiting) {
                    Text(waiting).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            Divider()
            HStack(spacing: 8) {
                Spacer()
                Button(CopilotConsentWords.refuse) { answer("refuse") }
                    .keyboardShortcut(.cancelAction)
                Button(CopilotConsentWords.allow) { answer("allow") }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 620, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The agent's own words, as text and nothing else, in the order it sent them.
    private var arguments: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(Array(request.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.name)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 64, alignment: .leading)
                    Text(row.value)
                        .font(.system(.footnote, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    /// The page drops it from the queue and shows the next one in this same sheet,
    /// or closes it when none is left.
    private func answer(_ action: String) {
        model.answerDialog(NativeDialogName.copilotConsent, action, argument: ["id": request.id], closes: false)
    }
}
