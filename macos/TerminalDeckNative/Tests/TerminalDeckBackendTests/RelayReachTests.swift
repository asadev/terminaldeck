import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// CRM-LINK 12 Oct: the relay only routes https://relay…/mcp/<host> to a Mac whose reach frame says 1
/// (relay/src/rendezvous.ts fromHostMcp: serving = payload[0] === 1). An empty payload meant "not serving".
final class RelayReachTests: XCTestCase {
    func testTheReachFrameSaysThisMacServesMCP() {
        XCTAssertEqual(BackendRemoteRelayClient.reachServing, Data([1]))
        XCTAssertEqual(BackendRemoteRelayClient.reachServing.first, 1, "the relay reads the first byte; 1 = serving")
    }
}

/// CRM-LINK 12 Oct (install 11): his app held no relay connection at all: a remote-start step before the relay
/// (devices, windows, credentials) never finished, so the relay was never dialled. The relay now comes up first,
/// and each step is logged.
final class RelayOrder: @unchecked Sendable { private let lock = NSLock(); private var list: [String] = []
    func add(_ e: String) { lock.withLock { list.append(e) } }
    var events: [String] { lock.withLock { list } } }
extension RelayReachTests {
    func testTheRelayIsDialledBeforeTheSlowerRemoteStepsAndSaysSo() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RELAYFIRST-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let trust = BackendRemoteTrustStore(directory: directory)
        try await trust.open()
        let host = BackendRemoteHost(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }),
                                     state: NativeStateStore(), home: directory.path, hostName: "Relay-first test Mac",
                                     appVersion: "test", privateRoots: [directory.path])
        let order = RelayOrder()
        BackendRemoteRelayClient.setLog { line in order.add("log: " + line) }
        defer { BackendRemoteRelayClient.setLog(nil) }
        let service = BackendRemoteHostService(endpoint: host, ownPorts: BackendDevOwnPorts(), relayURL: "ws://127.0.0.1:9/relay",
            webRoot: nil, tailnet: nil, hostName: "Relay-first test Mac",
            afterEndpointStart: { order.add("later steps"); throw NativeRPCError(code: "test", message: "stop here") },
            makeRelay: { url, identity, trust, host, mcp in
                order.add("relay dialled")
                return try BackendRemoteRelayClient(url: url, identity: identity, trust: trust, host: host, mcp: mcp) })
        _ = try? await service.start()
        try await Task.sleep(for: .milliseconds(200))
        let events = order.events
        let dialled = try XCTUnwrap(events.firstIndex(of: "relay dialled")), later = try XCTUnwrap(events.firstIndex(of: "later steps"))
        XCTAssertLessThan(dialled, later, "the relay comes up before the slower remote steps")
        XCTAssertTrue(events.contains("log: remote access: connecting to the relay"), "\(events)")
        await service.stop()
    }
}

extension RelayReachTests {
    /// CRM-LINK 12 Oct (install 12): the CRM's key (made by "Connect a CRM") was listed crm_task but every call was
    /// refused "no tool called crm_task" / "no tool called tools_run": its grant named only the id "crm.task".
    func testACRMOnlyKeyMayCallCrmTaskDirectlyAndThroughToolsRunAndNothingElse() {
        let grant = BackendDeckCoreSecurityAccessKeyDoor.crmOnlyTools
        XCTAssertTrue(BackendMCPToolNames.permits("crm_task", granted: grant))
        XCTAssertTrue(BackendMCPToolNames.permits("tools_run", granted: grant))
        for other in ["sessions_list", "tools_describe", "hoot_run", "tasks_local_change"] {
            XCTAssertFalse(BackendMCPToolNames.permits(other, granted: grant), other)
        }
    }
}
