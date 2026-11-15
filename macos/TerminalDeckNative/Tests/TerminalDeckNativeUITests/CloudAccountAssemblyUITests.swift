import Foundation
import Testing
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

@Suite("Cloud application assembly — production is forbidden in fixtures")
@MainActor
struct CloudAccountAssemblyUITests {
    @Test func aProductionConfigurationFailsBeforeProtectedStorage() throws {
        let calls = Calls()
        let protected = BackendCloudAccountProtectedStore(read: { calls.read(); return nil }, write: { _ in }, remove: {})
        let config = try CloudAccountConfiguration(baseURL: URL(string: CloudWire.productionBase)!, issuer: CloudWire.issuer,
            websiteStartURL: URL(string: "https://terminaldeck.dev/api/store/cloud/start")!, storeAuthURL: URL(string: CloudWire.issuer)!,
            publishableKey: "", deviceLabel: "Fixture", appVersion: "fixture", environment: .production)
        #expect(NativeCloudApplication.isTestProcess)
        #expect(throws: CloudFailure.unsafeConfiguration) {
            _ = try NativeCloudApplication.assemble(configuration: config,
                dataRoot: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Deck Dev/notes/cloud-test-20261112/a-forbidden-" + UUID().uuidString), protectedStore: protected,
                trustSlot: { _ in calls.read(); return .init(read: { nil }, write: { _ in }) })
        }
        #expect(calls.count == 0)
    }
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        func read() { lock.withLock { reads += 1 } }
        var count: Int { lock.withLock { reads } }
    }
}
