import SwiftUI
import TerminalDeckNativeCore

extension NativeHootChatModel {
    /// Capture the session owner, not a reusable view's State location. Delayed editor callbacks stay here.
    var ownedComposerBinding: Binding<HootComposerDraft> {
        let owner = self
        return Binding(get: { owner.composerDraft }, set: { owner.composerDraft = $0 })
    }
}

/// Outside the transcript's scroll view, so a long command never hides its status.
struct NativeChatWorkingLine: View {
    let state: ChatWorkingState
    var active = true
    var body: some View {
        if state.active {
            if active {
                TimelineView(.periodic(from: .now, by: 1)) { tick in
                    line(at: tick.date.timeIntervalSince1970 * 1000)
                }
            } else { line(at: Date().timeIntervalSince1970 * 1000) }
        }
    }
    private func line(at now: Double) -> some View {
        HStack(spacing: 8) {
            SessionStatusDot(status: "working", size: 6)
            Text((["Working", state.elapsed(at: now), state.detail].compactMap { $0 }).joined(separator: " · "))
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat-working-status")
    }
}
