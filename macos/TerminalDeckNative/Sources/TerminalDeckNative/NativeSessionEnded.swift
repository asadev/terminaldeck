import SwiftUI
import TerminalDeckNativeCore

/// What is drawn over a session's last frame once that frame is a photograph
/// (`shell/SessionEnded.tsx`): at the bottom of the pane, over the composer; what
/// happened, whether the work is still alive somewhere (the accent), and the one
/// press that does something about it — or no button at all when there is
/// nothing honest to offer. A scheduled redial counts down in the sentence.
struct NativeSessionEndedCard: View {
    let notice: SessionEndNotice
    /// The press; nil draws the card without the button rather than with a dead one.
    let act: ((SessionEndNotice.ActionID) -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            RoundedRectangle(cornerRadius: 2)
                .fill(notice.alive ? Color.accentColor : Color.secondary)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.callout.weight(.semibold))
                detail
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
            if let action = notice.action, let act {
                Button(action.label) { act(action.id) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// The one timer here: a countdown to a retry the link already announced, which
    /// stops once its moment has passed.
    @ViewBuilder private var detail: some View {
        if let retryAt = notice.retryAt, retryAt > Date().timeIntervalSince1970 * 1000 - 1000 {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(notice.detail(nowMs: context.date.timeIntervalSince1970 * 1000))
            }
        } else {
            Text(notice.retryAt == nil ? notice.detail : notice.detail(nowMs: Date().timeIntervalSince1970 * 1000))
        }
    }
}
