import Foundation
import Testing
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

/// Saved passwords exist only when the account assembly is handed everything they need. No fixture hands it over.
@Suite("Cloud saved passwords — absent unless handed in")
@MainActor
struct CloudSecretsWiringUITests {
    @Test func theRealKeyPlaceIsRefusedInATestProcess() {
        #expect(NativeCloudApplication.isTestProcess)
        #expect(throws: CloudFailure.unsafeConfiguration) { _ = try NativeCloudSecretsLive.keychain(appName: "Fixture") }
    }
    @Test func savedPasswordsAreOnAsProvenAndHandedOverOnlyWhenTheAppsOwnersExist() {
        // 0.22.0: the proof has passed, so saved passwords are on (the same rule as the memory rows). They are built
        // only while an account is being assembled, which needs a signed-in, allowed account (CloudGateInert*).
        #expect(NativeCloudSecretsSwitch.proven)
        #expect(NativeCloudScratch.active == nil)
        #expect(NativeCloudSecretsSwitch.on)
        let before = NativeCloudApplication.liveSecrets
        defer { NativeCloudApplication.liveSecrets = before }
        // No app owners (fixtures): no hand-over, nothing of saved passwords is built.
        NativeCloudApplication.liveSecrets = nil
        #expect(NativeCloudApplication.secretsHandOver(appName: "Fixture") == nil)
        // With owners the assembly asks them, and an owner that has nothing hands over nothing.
        let asked = Reached()
        NativeCloudApplication.liveSecrets = { _ in asked.mark(); return nil }
        let handOver = NativeCloudApplication.secretsHandOver(appName: "Fixture")
        #expect(handOver == nil)
        #expect(asked.value())
    }
    @Test func withoutTheHandOverThereIsNoSectionNoPressAndNoConfirmedWords() async throws {
        let model = NativeCloudSecrets()
        #expect(model.page == nil)
        #expect(model.graph == nil)
        // Presses with nothing wired do nothing; in particular the login-store action is never reached.
        let reached = Reached()
        model.allowLoginStoreAction = { reached.mark() }
        model.reload()
        model.perform(.setup)
        model.addWaiting("fixture")
        model.dismissWaiting("fixture")
        model.dismissNotices()
        model.syncNow()
        model.allowLoginStore()
        #expect(model.page == nil)
        #expect(!model.busy)
        #expect(!reached.value())
        // The shared model is only ever given a graph by the account assembly's hand-over.
        #expect(NativeCloudSecrets.shared.graph == nil)
        #expect(NativeCloudSecrets.shared.page == nil)
        #expect(try await NativeCloudSecrets.recoveryWordsConfirmed() == false)
    }
    private final class Reached: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func mark() { lock.withLock { done = true } }
        func value() -> Bool { lock.withLock { done } }
    }
}
