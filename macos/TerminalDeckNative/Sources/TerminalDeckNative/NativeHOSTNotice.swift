import SwiftUI
import Observation
import TerminalDeckBackend

/// What the side panel says about the session host. Quiet by default:
///  - a session that runs in the app by design (`.inApp`) says nothing, ever;
///  - the failure line shows only when the host really failed to start or connect, once,
///    and stays gone after "Dismiss" until a different failure comes up.
/// A real failure is one compact row inside Running; normal host states are silent.
@MainActor
struct NativeHOSTNotice: View {
    enum State: Equatable {
        case checking
        case running
        /// A session that runs in the app BY DESIGN (an AI session using Terminal Deck's tools or managed
        /// accounts is not host-eligible yet). Nothing to say: this is never shown.
        case inApp
        /// The session host really failed to start or connect. Shown once, dismissible.
        case fallback(reason: String)
    }
    @Binding var state: State
    let retry: @MainActor () async throws -> State
    @State private var retrying = false
    @State private var retryError: String?
    private let dismissals = NativeHOSTNoticeDismissals.shared

    /// Whether anything shows at all (the footer uses it to keep its spacing tight).
    static func shows(_ state: State, dismissed: String?) -> Bool {
        switch state {
        case .checking, .inApp: false
        case .running: false
        case .fallback(let reason): reason != dismissed
        }
    }

    var body: some View {
        if Self.shows(state, dismissed: dismissals.dismissedReason) {
            if case .fallback(let reason) = state {
                HStack(spacing: 0) {
                    Button {
                        guard !retrying else { return }
                        retrying = true; retryError = nil
                        Task { @MainActor in
                            defer { retrying = false }
                            do {
                                state = try await retry()
                                // Pages that failed while the host was down read again by themselves.
                                if case .running = state { DeckReconnect.shared.back("the session host is running again") }
                            }
                            catch { retryError = "Couldn’t restart the session host. Try again." }
                        }
                    } label: {
                        Text(retrying ? "Session host stopped · Restarting…" : retryError == nil ? "Session host stopped · Restart" : "Session host stopped · Try again")
                            .font(.system(size: 11)).foregroundStyle(.red).lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(.rect)
                    }
                    .buttonStyle(SIDEBARRowStyle()).disabled(retrying)
                    .help(retryError ?? reason)
                    Button { dismissals.dismissedReason = reason } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                            .frame(width: 28, height: 28).contentShape(.rect)
                    }
                    .buttonStyle(SIDEBARRowStyle()).help("Dismiss").accessibilityLabel("Dismiss session host notice")
                }
                .contextMenu {
                    Button("Dismiss") { dismissals.dismissedReason = reason }
                }
            }
        }
    }
}

/// The failure the person dismissed: it stays quiet until a different failure comes up.
@MainActor @Observable
final class NativeHOSTNoticeDismissals {
    static let shared = NativeHOSTNoticeDismissals()
    var dismissedReason: String?
}

/// The notice as the sidebar footer draws it: the session-host core's own state, if there is one.
@MainActor
struct NativeHOSTNoticeSlot: View {
    let model: AppModel

    var body: some View {
        if let host = NativeCompositionINT2HOSTCore.current {
            NativeHOSTNotice(state: Binding(get: { host.notice }, set: { host.notice = $0 }),
                             retry: { try await host.retry() })
        }
        NativeSessionRunawayNote()
    }
}
