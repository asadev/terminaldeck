import SwiftUI
import TerminalDeckNativeCore

// The ended session's page (review of 18 Nov, item 13: "If any session is ended, we can have a better nice page than
// this page. This page is very ugly"). Before: a bare strip across an empty grey page with a blue button at its far
// end. Now: the last screen stays where it was, under a veil of the session's own paper so it reads as past, and ONE
// card in the middle says what happened in plain words, with "Start again here" and a quiet "Close session".
// Numbers: DESIGN-shell.md §3.

/// What the card says and shows for one kind of ending (pure, so a test and a picture read the same words).
enum NativeSessionEndedLook {
    enum Tone: Equatable { case finished, error, alive, stopped }
    struct Words: Equatable {
        let tone: Tone
        let symbol: String
        let title: String
        /// nil: the notice's own sentence (with its countdown) is shown.
        let detail: String?
        /// The blue button's words; nil keeps the notice's own.
        let action: String?
    }

    static func words(_ end: SessionEnd?, notice: SessionEndNotice) -> Words {
        if case .exited(let code)? = end {
            let failed = (code ?? 0) != 0
            return Words(tone: failed ? .error : .finished, symbol: failed ? "exclamationmark" : "checkmark",
                         title: failed ? "This session stopped with an error" : "This session ended",
                         detail: (failed ? "The program exited with status \(code ?? 0)." : "The program finished.")
                             + " Its last screen is still here.",
                         action: "Start again here")
        }
        // Every other ending keeps the words that explain it (another device not answering, a server's shell closed).
        return Words(tone: notice.alive ? .alive : .stopped, symbol: notice.alive ? "arrow.triangle.2.circlepath" : "power",
                     title: notice.title, detail: nil, action: nil)
    }
}

/// The ended session's page: the veil over the last screen and the card in its middle.
struct NativeSessionEndedPage: View {
    let end: SessionEnd
    /// The session's own paper colour (the veil is this at 62%).
    let ground: Color
    /// The blue button's press; nil draws the card without it rather than with a dead one.
    let act: ((SessionEndNotice.ActionID) -> Void)?
    /// "Close session"; nil leaves it out.
    var close: (() -> Void)? = nil

    var body: some View {
        ZStack {
            // The last screen can still be scrolled and copied from: the veil takes no clicks.
            ground.opacity(0.62).allowsHitTesting(false)
            NativeSessionEndedCard(notice: end.notice, act: act, end: end, close: close)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The card: a round tile with the ending's glyph, what happened, one sentence, the one blue action and a quiet
/// second one. A solid surface (the app's menu surface), never glass. A scheduled redial counts down in the sentence.
struct NativeSessionEndedCard: View {
    let notice: SessionEndNotice
    /// The press; nil draws the card without the button rather than with a dead one.
    let act: ((SessionEndNotice.ActionID) -> Void)?
    /// Which ending it is, for the plain words; nil keeps the notice's own.
    var end: SessionEnd? = nil
    var close: (() -> Void)? = nil
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let words = NativeSessionEndedLook.words(end, notice: notice)
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(spacing: 0) {
            Image(systemName: words.symbol).font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint(words.tone))
                .frame(width: 40, height: 40)
                .background(tint(words.tone).opacity(words.tone == .finished || words.tone == .stopped ? 0.10 : 0.14), in: .circle)
                .accessibilityHidden(true)
            Text(words.title)
                .font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 12)
            Group {
                if let detail = words.detail { Text(detail) } else { noticeDetail }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 5)
            if let action = notice.action, let act {
                Button { act(action.id) } label: {
                    Text(words.action ?? action.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                        .padding(.horizontal, 16)
                        .frame(minWidth: 168, minHeight: 28)
                        .background(Color.accentColor, in: .rect(cornerRadius: 7, style: .continuous))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.top, 16)
            }
            if let close {
                Button(action: close) {
                    Text("Close session").font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).frame(minHeight: 24).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
        }
        .padding(22)
        .frame(width: 340)
        .background(DeckMenuColours.surface, in: shape)
        .overlay(shape.strokeBorder(DeckMenuColours.border, lineWidth: 1 / max(displayScale, 1)))
        .shadow(color: DeckMenuColours.contactShadow(scheme), radius: 1.5, y: 1)
        .shadow(color: DeckMenuColours.shadow(scheme), radius: 20, y: 9)
        .padding(24)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func tint(_ tone: NativeSessionEndedLook.Tone) -> Color {
        switch tone {
        case .finished, .stopped: return Color.secondary
        case .error: return DeckTokens.warn
        case .alive: return Color.accentColor
        }
    }

    /// The one timer here: a countdown to a retry the link already announced, which
    /// stops once its moment has passed (one tick a second, the last just after it).
    @ViewBuilder private var noticeDetail: some View {
        if let retryAt = notice.retryAt, retryAt > Date().timeIntervalSince1970 * 1000 - 1000 {
            TimelineView(.explicit(Self.ticks(until: retryAt))) { context in
                Text(notice.detail(nowMs: context.date.timeIntervalSince1970 * 1000))
            }
        } else {
            Text(notice.retryAt == nil ? notice.detail : notice.detail(nowMs: Date().timeIntervalSince1970 * 1000))
        }
    }

    static func ticks(until retryAtMs: Double, from now: Date = .now) -> [Date] {
        Array(stride(from: now, through: Date(timeIntervalSince1970: retryAtMs / 1000 + 1), by: 1))
    }
}
