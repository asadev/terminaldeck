import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

// Lane S5. Small remaining cases from session-activity.test.ts and session-held.test.ts.

@Suite("S5 sessions: activity text and screen (session-activity.test.ts)")
struct BackendFoundationTestsS5SessionsActivity {
    // TS session-activity.test.ts:5
    @Test func stripAnsiRemovesColourCodes() { #expect(BackendSharedText.stripAnsi("\u{1b}[31mred\u{1b}[0m") == "red") }
    // TS session-activity.test.ts:9
    @Test func stripAnsiRemovesOSCTitleSequences() { #expect(BackendSharedText.stripAnsi("\u{1b}]0;my title\u{07}text") == "text") }
    // TS session-activity.test.ts:109 — the repaint-last case, driven through the production viewport helper (no PTY, no timer).
    @Test func classifiesFromTheRenderedScreenNotTheRawStreamOrder() throws {
        let chunks = ["\u{1b}[2J\u{1b}[H", "Accessing workspace:\r\n\r\n", "\u{1b}[32m❯ 1. Yes, I trust this folder\u{1b}[0m\r\n",
                      "  2. No, exit\r\n", "\u{1b}[1;1H\u{1b}[KAccessing workspace:"].map { Data($0.utf8) }
        let viewport = try BackendPTYManager.viewportForTesting(cols: 80, rows: 24, chunks: chunks)
        #expect(BackendSessionClassifier.classify(viewport: viewport) == .input)
    }
    // TS session-activity.test.ts:129
    @Test func exitIsTheTerminalState() { #expect(BackendSessionClassifier.classify(viewport: "hello", exited: true) == .exited) }
    // TS session-activity.test.ts:146 — skipped: the TS emulator parses asynchronously (settledText vs visibleText); Swift feeds SwiftTerm synchronously, so there is no unflushed-read state to observe.
}

final class BackendFoundationTestsS5SessionsCounter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    var observation: NativeRPCSubscription?
    func bump() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@Suite("S5 sessions: telling whoever is holding it (session-held.test.ts:176)")
struct BackendFoundationTestsS5SessionsHeldChange {
    private func saved() -> NativeRPCValue {
        .object([.init("cwd", .string("/w")), .init("provider", .string("claude")), .init("profileId", .null), .init("cols", .number(100)), .init("rows", .number(30)), .init("lastSeenAt", .number(1_000))])
    }
    private func started() async throws -> (NativeStateStore, BackendFoundationTestsS5SessionsCounter) {
        let store = NativeStateStore(initialState: NativeStateStore.defaults)
        try await store.startSessionLedger()
        let counter = BackendFoundationTestsS5SessionsCounter()
        counter.observation = await store.observeSnapshot { _ in counter.bump() }   // retain through all changes; seeds once
        return (store, counter)
    }
    // TS session-held.test.ts:176 (hold, fail, release each announce exactly one change)
    @Test func eachRealChangeFiresOnce() async throws {
        let (store, counter) = try await started(); let seed = counter.count
        let entry = try await store.holdSession(saved(), reason: "no")
        #expect(counter.count - seed == 1)
        try await store.failHeldSession(entry.key, reason: "still no")
        #expect(counter.count - seed == 2)
        _ = try await store.releaseHeldSession(entry.key)
        #expect(counter.count - seed == 3)
    }
    // TS session-held.test.ts:176 (no-op half)
    @Test func noOpsFireNothing() async throws {
        let (store, counter) = try await started()
        let entry = try await store.holdSession(saved(), reason: "no"); let before = counter.count
        try await store.failHeldSession("held-99", reason: "nobody")
        #expect(counter.count == before)
        _ = try await store.releaseHeldSession(entry.key); let released = counter.count
        _ = try await store.releaseHeldSession(entry.key)
        #expect(counter.count == released)
    }
}
