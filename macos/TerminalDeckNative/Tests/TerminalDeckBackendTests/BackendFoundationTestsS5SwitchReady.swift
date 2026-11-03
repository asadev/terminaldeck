import Foundation
import Testing
@testable import TerminalDeckBackend

// Seam S5-6 landed (lane P1); the build flag guard is gone.

/// A fake clock: `sleep` advances `now` instead of waiting, so nothing here ever really sleeps.
private final class FakeClock: @unchecked Sendable {
    var now = 0
    var sleeps: [Int] = []
}
private let prompt = "Welcome back\n\n❯ \n────────\n? for shortcuts"

private func probe(_ clock: FakeClock, screen: String?, diesAfter: Int? = nil, alive: Bool = true, scrollback: String = "") -> BackendSessionReplacementReadiness.Probe {
    BackendSessionReplacementReadiness.Probe(
        alive: { alive && (diesAfter == nil || clock.now < diesAfter!) },
        screen: { screen }, scrollback: { scrollback },
        sleep: { ms in clock.sleeps.append(ms); clock.now += ms })
}
private func ready(_ clock: FakeClock, _ p: BackendSessionReplacementReadiness.Probe) async throws -> BackendSessionReplacementReadiness.Result {
    try await BackendSessionReplacementReadiness.awaitReady(sessionID: "replacement", probe: p, ceilingMilliseconds: 4_000, intervalMilliseconds: 50)
}

@Suite("S5 switch reliability: the replacement is judged by a real readiness signal (fake clock)")
struct BackendFoundationTestsS5SwitchReady {
    // TS session-switch-reliability.test.ts:172
    @Test func movesOnTheMomentTheReplacementShowsItsPrompt() async throws {
        let clock = FakeClock(); let result = try await ready(clock, probe(clock, screen: prompt))
        #expect(result.outcome == .ready); #expect(clock.now < 1_000)
    }
    // TS session-switch-reliability.test.ts:185
    @Test func keepsTheSessionWhenTheReplacementDiesAfterTheOldFixedWaitWouldHavePassedIt() async throws {
        let clock = FakeClock(); let result = try await ready(clock, probe(clock, screen: "Resuming conversation…", diesAfter: 2_000))
        #expect(result.outcome == .died); #expect(clock.now >= 2_000)
    }
    // TS session-switch-reliability.test.ts:198 (outcome half; the user-facing sentence is covered by the REQ S5-5 message tests)
    @Test func keepsTheSessionWhenTheReplacementComesUpAtASignInScreen() async throws {
        let clock = FakeClock(); let result = try await ready(clock, probe(clock, screen: "Not logged in · Please run /login"))
        #expect(result.outcome == .signedOut); #expect(result.said == "Not logged in · Please run /login")
    }
    // TS session-switch.test.ts:360 (the survival probe, as awaitReady: not alive -> the agent's own last words)
    @Test func reportsTheAgentsOwnLastWordsWhenItIsNotAlive() async throws {
        let clock = FakeClock()
        let result = try await ready(clock, probe(clock, screen: nil, alive: false, scrollback: "Some earlier output\r\nNo conversation found to continue\r\n\r\n"))
        #expect(result.outcome == .died); #expect(result.said == "No conversation found to continue")
    }
    // TS session-switch.test.ts:371
    @Test func doesNotInventAReasonWhenTheProcessSaidNothing() async throws {
        let clock = FakeClock(); let result = try await ready(clock, probe(clock, screen: nil, alive: false, scrollback: "   \n\n"))
        #expect(result.outcome == .died); #expect(result.said == nil)
    }
    // TS session-switch.test.ts:356
    @Test func saysNothingIsWrongWhenTheSessionIsStillThere() async throws {
        let clock = FakeClock(); let result = try await ready(clock, probe(clock, screen: nil))
        #expect(result.outcome == .started); #expect(result.said == nil)
    }
    // TS session-switch.test.ts:348
    @Test func waitsBeforeDecidingBecauseARefusalTakesAMomentToArrive() async throws {
        let clock = FakeClock(); _ = try await ready(clock, probe(clock, screen: nil))
        #expect(clock.sleeps.first == 1_500)
    }
    // 18 Oct (#446): while the replacement says nothing, its screen is not read again and again: one wait for its next
    // event, up to the ceiling.
    @Test func waitsForTheSessionToSaySomethingInsteadOfReadingItsScreenOverAndOver() async throws {
        let clock = FakeClock(); let result = try await ready(clock, probe(clock, screen: "Resuming conversation…"))
        #expect(result.outcome == .started); #expect(clock.sleeps == [4_000])
    }
    // 18 Oct (#446): new output while a prompt is being confirmed starts the judgement again.
    @Test func outputDuringTheConfirmationIsJudgedAgain() async throws {
        let clock = FakeClock(), woken = FakeClock()
        let probe = BackendSessionReplacementReadiness.Probe(alive: { true }, screen: { prompt }, scrollback: { "" },
            wait: { ms in
                clock.sleeps.append(ms)
                // The first confirmation is cut short by output; the next one is quiet.
                if woken.now == 0 { woken.now = 1; clock.now += 10; return 10 }
                clock.now += ms; return ms
            })
        let result = try await ready(clock, probe)
        #expect(result.outcome == .ready); #expect(clock.sleeps == [50, 50])
    }
    // 18 Oct (#446): the bell wakes the wait at the session's own event, or at the end of its time.
    @Test func theBellWakesTheWaitAtTheSessionsOwnEvent() async {
        let bell = BackendSessionReplacementReadiness.Bell()
        bell.ring(); #expect(await bell.wait(milliseconds: 10_000) == 0)
        Task { try? await Task.sleep(for: .milliseconds(20)); bell.ring() }
        #expect(await bell.wait(milliseconds: 10_000) < 5_000)
        #expect(await bell.wait(milliseconds: 30) >= 1)
    }
}
