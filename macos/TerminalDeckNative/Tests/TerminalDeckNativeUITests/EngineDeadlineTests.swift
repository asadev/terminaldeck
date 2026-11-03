import Foundation
import Testing
@testable import TerminalDeckNative

@Suite("Engine deadlines")
@MainActor
struct EngineDeadlineTests {
    @Test func answerAndFailureUseTheSameTransport() async throws {
        let answer = try await EngineDeadline.invoke("servers:list", what: "reading servers", seconds: 1) { channel, args in
            #expect(channel == "servers:list" && args.isEmpty)
            return "ready"
        }
        #expect(answer as? String == "ready")
        let failure = RemoteError("Server unavailable.")
        #expect(EngineDeadline.serverText(failure, fallback: "Fallback") == "Server unavailable.")
    }

    @Test func timeoutCancelsTheCallAndKeepsItsMessage() async throws {
        do {
            _ = try await EngineDeadline.invoke("servers:folder", what: "listing that folder", seconds: 0.01) { _, _ in
                try await Task.sleep(for: .seconds(60))
                return "late"
            }
            Issue.record("A timed-out call returned a value.")
        } catch {
            #expect(error is EngineDeadline.Overdue)
            #expect(EngineDeadline.serverText(error, fallback: "Fallback") == EngineDeadline.describe(error))
        }
    }
}
