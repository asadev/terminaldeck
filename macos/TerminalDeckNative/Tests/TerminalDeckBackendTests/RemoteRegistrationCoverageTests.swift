import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Remote registration ownership")
struct RemoteRegistrationCoverageTests {
    @Test func registrationIsInertAtomicAndItsLeaseKeepsOtherOwnersIntact() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("remote-registration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = Calls()
        let host = BackendRemoteHost(trust: .init(directory: root),
            manager: .init(inheritedEnvironment: [:], onEvent: { _ in }), state: .init(),
            home: root.path, hostName: "Test", appVersion: "test", privateRoots: [])
        let adapter = BackendRemoteServeRegistrationHostAdapter(endpoint: host)
        let suppliers = BackendRemoteServeRegistration.Suppliers(requireReady: { calls.note() }, create: nil, enrollment: nil,
            drivesWindows: { _ in calls.note(); return false }, sessionVisible: { _, _ in calls.note(); return false },
            isHidden: { _ in calls.note(); return false }, accountShared: { _, _ in calls.note(); return false },
            anyAccount: { _ in calls.note(); return false }, legacyCredential: { _, _ in calls.note() },
            missingFeature: { _ in calls.note(); return nil }, guestRefusal: { _ in calls.note(); return nil })
        let hooks = BackendRemoteServeRegistration.Hooks(connectionsChanged: { calls.note() }, rosterChanged: { calls.note() },
            lastDeviceDisconnected: { _ in calls.note() }, windowHolds: { _, _ in calls.note() })
        let settings = BackendRemoteHostFeature(capability: "settings", messageTypes: ["settings.read"]) { _, _ in calls.note(); return [] }
        let usage = BackendRemoteHostFeature(capability: "usage", messageTypes: ["usage.read"]) { _, _ in calls.note(); return [] }
        let independent = try await host.installFeatures(ownerID: "independent", features: [settings], connectionClosed: { _ in calls.note() })
        do {
            let unexpected = try await adapter.install(ownerID: "bad", features: [usage, settings], suppliers: suppliers, hooks: hooks)
            await unexpected.cancelAndWait()
            Issue.record("A conflicting feature installation was accepted")
        } catch {}
        // The rejected batch must not leave usage.read behind or reserve the area.
        let lease = try await adapter.install(ownerID: "remote", features: [usage], suppliers: suppliers, hooks: hooks)
        do {
            let unexpected = try await adapter.install(ownerID: "second-owner", features: [], suppliers: suppliers, hooks: hooks)
            await unexpected.cancelAndWait()
            Issue.record("A second remote-serve owner was accepted")
        } catch let error as NativeRPCError { #expect(error.code == "composition-conflict") }
        await lease.cancelAndWait()
        await lease.cancelAndWait()
        let replacement = try await adapter.install(ownerID: "replacement", features: [usage], suppliers: suppliers, hooks: hooks)
        do {
            try await host.register(settings)
            Issue.record("Remote-serve cleanup removed another owner's handler")
        } catch {}
        await replacement.cancelAndWait()
        await independent.cancelAndWait()
        try await host.register(settings)
        #expect(calls.count == 0)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func note() { lock.withLock { value += 1 } }
    }
}
