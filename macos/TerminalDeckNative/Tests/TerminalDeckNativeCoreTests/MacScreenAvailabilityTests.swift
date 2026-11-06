import Testing
@testable import TerminalDeckNativeCore

@Suite("Phone screen sleep and lock recovery")
@MainActor struct MacScreenAvailabilityTests {
    @MainActor final class Probe {
        var state: MacScreenAvailability.State = .awake
        var reads = 0, wakes = 0, waits = 0
        var emptyReads = 0
        var wakeSucceeds = true
        var stateAfterWait: MacScreenAvailability.State = .awake
        var notes: [String] = []
        var lockDuringProgress = false
        var helperApproved = false
        func capture(allowed: Bool = true) async throws -> [Int] {
            try await MacScreenAvailability.capture(mayWake: allowed, state: { self.state }, helperApproved: { self.helperApproved }, read: {
                self.reads += 1
                return self.reads <= self.emptyReads ? [] : [4]
            }, isEmpty: { $0.isEmpty }, wake: {
                self.wakes += 1
                return self.wakeSucceeds
            }, wait: {
                self.waits += 1
                self.state = self.stateAfterWait
            }, progress: {
                self.notes.append($0)
                if self.lockDuringProgress { self.state = .locked }
            })
        }
        func failure(allowed: Bool = true) async -> String? {
            do { _ = try await capture(allowed: allowed); return nil }
            catch let error as MacScreenAvailability.Failure { return error.message }
            catch { Issue.record("Unexpected failure: \(error)"); return nil }
        }
    }
    @Test func asleepWakesOnceThenCaptures() async throws {
        let probe = Probe(); probe.state = .asleep
        #expect(try await probe.capture() == [4])
        #expect(probe.wakes == 1 && probe.reads == 1 && probe.waits == 1)
        #expect(probe.notes == [MacScreenAvailability.waking])
    }
    @Test func lockedCaptureIsKeptWithoutHelperOrWake() async throws {
        let probe = Probe(); probe.state = .locked
        #expect(try await probe.capture(allowed: false) == [4])
        #expect(probe.wakes == 0 && probe.reads == 1 && probe.waits == 0)
    }
    @Test func lockedWithoutPicturesWakesAndRetriesBeforeMessage() async {
        let probe = Probe(); probe.state = .locked; probe.stateAfterWait = .locked; probe.emptyReads = 10
        #expect(await probe.failure() == MacScreenAvailability.locked)
        #expect(probe.wakes == 1 && probe.reads == 2 && probe.waits == 1)
    }
    @Test func approvedHelperNeverGetsTheUnlockToSeeMessage() async {
        let probe = Probe(); probe.state = .locked; probe.stateAfterWait = .locked; probe.emptyReads = 10; probe.helperApproved = true
        #expect(await probe.failure() == MacScreenAvailability.unavailable)
        #expect(probe.wakes == 1 && probe.reads == 2 && probe.waits == 1)
    }
    @Test func lockedTemporaryEmptyCaptureRecoversAfterOneWake() async throws {
        let probe = Probe(); probe.state = .locked; probe.stateAfterWait = .locked; probe.emptyReads = 1
        #expect(try await probe.capture() == [4])
        #expect(probe.wakes == 1 && probe.reads == 2 && probe.waits == 1)
    }
    @Test func failedLockedWakeStillRetriesCaptureBeforeMessage() async {
        let probe = Probe(); probe.state = .locked; probe.stateAfterWait = .locked
        probe.emptyReads = 10; probe.wakeSucceeds = false
        #expect(await probe.failure() == MacScreenAvailability.locked)
        #expect(probe.wakes == 1 && probe.reads == 2 && probe.waits == 1)
    }
    @Test func workAccessCannotWake() async {
        let probe = Probe(); probe.state = .asleep
        #expect(await probe.failure(allowed: false) == MacScreenAvailability.wakeRefused)
        #expect(probe.wakes == 0 && probe.reads == 0 && probe.notes.isEmpty)
    }
    @Test func workAccessCanReadAnAwakeDisplay() async throws {
        let probe = Probe()
        #expect(try await probe.capture(allowed: false) == [4])
        #expect(probe.wakes == 0 && probe.reads == 1 && probe.waits == 0)
    }
    @Test func emptyInventoryRetriesOnlyOnceWithoutClaimingUnplugged() async {
        let probe = Probe(); probe.emptyReads = 10
        #expect(await probe.failure() == MacScreenAvailability.unavailable)
        #expect(probe.reads == 2 && probe.waits == 1 && probe.wakes == 0)
    }
    @Test func temporaryEmptyInventoryRecovers() async throws {
        let probe = Probe(); probe.emptyReads = 1
        #expect(try await probe.capture() == [4])
        #expect(probe.reads == 2 && probe.wakes == 0)
    }
    @Test func lockingDuringWakeStillTriesCapture() async throws {
        let probe = Probe(); probe.state = .asleep; probe.stateAfterWait = .locked
        #expect(try await probe.capture() == [4])
        #expect(probe.reads == 1 && probe.wakes == 1)
    }
    @Test func stillAsleepAfterRetryHasAnHonestMessage() async {
        let probe = Probe(); probe.state = .asleep; probe.stateAfterWait = .asleep; probe.emptyReads = 10
        #expect(await probe.failure() == MacScreenAvailability.asleep)
        #expect(probe.wakes == 1 && probe.reads == 1 && probe.waits == 1)
    }
    @Test func lockingWhileProgressIsSentStillCaptures() async throws {
        let probe = Probe(); probe.state = .asleep; probe.lockDuringProgress = true
        #expect(try await probe.capture() == [4])
        #expect(probe.wakes == 1 && probe.reads == 1 && probe.waits == 1)
    }
    @Test func unknownSessionFailsWithoutWakingOrReading() async {
        let probe = Probe(); probe.state = .unknown
        #expect(await probe.failure() == MacScreenAvailability.unavailable)
        #expect(probe.reads == 0 && probe.wakes == 0)
    }
    @Test func failedWakeDoesNotLoop() async {
        let probe = Probe(); probe.state = .asleep; probe.wakeSucceeds = false
        #expect(await probe.failure() == MacScreenAvailability.asleep)
        #expect(probe.wakes == 1 && probe.reads == 0 && probe.waits == 0)
    }
}
