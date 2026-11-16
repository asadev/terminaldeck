import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Proof 3 (13 Nov), defect 4: a Pause press did not show on one Mac, and "19 changes still to fetch" stayed for about
/// two minutes after everything had arrived (the count was read only at the next full status read).
@Suite("Cloud — Pause shows at once, and a finished fetch clears its count")
struct CloudPauseAndFetchedTests {
    @Test func pauseShowsAtOnceEvenWhenTheStatusReadAfterItCannotFinish() async throws {
        let f = try CloudAccountFixture.make()
        _ = try await f.signin()
        await f.transport.setOffline(true)
        try await f.account.sync(action: "pause")
        #expect(await f.account.state().phase == .paused)
        #expect(await f.outbox.paused)
        try await f.account.sync(action: "resume")
        #expect(await f.account.state().phase == .signedIn)
        #expect(await f.outbox.paused == false)
        await f.transport.setOffline(false)
    }
    @Test func theStillToFetchCountClearsWhenTheFetchHasFinished() async throws {
        let f = try CloudAccountFixture.make()
        _ = try await f.signin()
        await f.transport.setHead(CloudSequence(40))
        await f.outbox.setFetched(CloudSequence(21))
        try await f.account.refresh()
        #expect(await f.account.state().behindBy == 19)
        // Everything arrived: this Mac's own progress, read again without asking the service, clears the count.
        await f.outbox.setFetched(CloudSequence(40))
        let calls = await f.transport.stateCalls
        await f.account.refreshLocalProgress()
        let after = await f.account.state()
        #expect(after.catchingUp == false)
        #expect(after.behindBy == 0)
        #expect(await f.transport.stateCalls == calls)
        // Read past the last head it was told: level, never "behind" by a negative or stale count.
        await f.outbox.setFetched(CloudSequence(44))
        await f.account.refreshLocalProgress()
        #expect(await f.account.state().catchingUp == false)
    }
}
