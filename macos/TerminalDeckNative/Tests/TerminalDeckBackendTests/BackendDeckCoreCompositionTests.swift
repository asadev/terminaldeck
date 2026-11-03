import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendDeckCoreCompositionTests: XCTestCase {
    private func context(_ owner: String) -> NativeRPCContext { .init(caller: .nativeApp, ownerID: owner) }
    func testTrustedSiblingWindowCannotAnswerWithoutEnrolling() async throws {
        let window = BackendDeckCoreWindowConsent(isApprover: { _ in true }, send: { _, _, _ in true }, broadcast: { _, _ in })
        let broker = BackendDeckCoreSecurityConsentBroker(ask: { _ in false })
        _ = try await window.attach(context: context("one"), broker: broker)
        do {
            _ = try await window.respond(context: context("two"), broker: broker, id: .string("stale"), approved: .bool(true))
            XCTFail("A trusted sibling that did not display the question must be refused")
        } catch let error as NativeRPCError { XCTAssertEqual(error.code, "access-denied") }
        let result = try await window.respond(context: context("one"), broker: broker, id: .string("stale"), approved: .bool(true))
        XCTAssertEqual(result["accepted"], .bool(false))
    }
    func testWindowDestroyMakesItsIdentityUnusableImmediately() async throws {
        let window = BackendDeckCoreWindowConsent(isApprover: { _ in true }, send: { _, _, _ in true }, broadcast: { _, _ in })
        let broker = BackendDeckCoreSecurityConsentBroker(ask: { _ in false })
        _ = try await window.attach(context: context("one"), broker: broker)
        await window.gone(ownerID: "one", broker: broker)
        let accepts = await window.accepts(context("one"))
        XCTAssertFalse(accepts)
        do { _ = try await window.attach(context: .init(caller: .page, ownerID: "page"), broker: broker) }
        catch { XCTFail("The supplied trust callback controls enrolment; caller kind alone is not its policy") }
    }
    func testOwnerTrustCallbackRefusesUntrustedWindow() async {
        let window = BackendDeckCoreWindowConsent(isApprover: { $0.ownerID == "one" }, send: { _, _, _ in true }, broadcast: { _, _ in })
        let broker = BackendDeckCoreSecurityConsentBroker(ask: { _ in false })
        do { _ = try await window.attach(context: context("two"), broker: broker); XCTFail("Untrusted enrolment must be refused") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "access-denied") }
        catch { XCTFail("Expected the exact owner refusal") }
    }
    func testTwoConfigFilesCarryDifferentCredentialsForSameListeningEndpoint() throws {
        let endpoint = BackendDeckCoreSecurityEndpoint(port: 47821, token: String(repeating: "a", count: 64), unattendedToken: String(repeating: "b", count: 64),
            url: URL(string: "http://127.0.0.1:47821/mcp")!, callers: BackendDeckCoreSecurityCallerTable())
        let attended = try NativeRPCValue.parseJSON(BackendDeckCoreConfiguration.mcpConfigFor(endpoint))
        let unattended = try NativeRPCValue.parseJSON(BackendDeckCoreConfiguration.mcpConfigFor(endpoint, unattended: true))
        XCTAssertEqual(attended["mcpServers"]["deck-control"]["url"], unattended["mcpServers"]["deck-control"]["url"])
        XCTAssertNotEqual(attended["mcpServers"]["deck-control"]["headers"]["Authorization"], unattended["mcpServers"]["deck-control"]["headers"]["Authorization"])
        XCTAssertNotEqual(BackendDeckCoreConfiguration.attendedFile, BackendDeckCoreConfiguration.unattendedFile)
        XCTAssertThrowsError(try BackendDeckCoreConfiguration.write(endpoint: endpoint, copilotRoot: URL(fileURLWithPath: "/does-not-get-written"), ownership: .readOnly))
    }
    func testDisclosureCannotDiscardContributedPolicies() throws {
        let tool = try BackendMCPTool(id: "example.read", wireName: "example_read", description: "Read", inputSchema: .object([]), tier: .read)
        let area = try BackendDeckCoreToolArea(id: "example", tools: [tool], describeText: "Read", handlers: [tool.id: { _, _ in .value(.null) }])
        XCTAssertThrowsError(try BackendDeckCoreAreaIntegration.bundle(area: area, metadata: [.init(tool: tool, title: "Read")], policies: []))
    }
}
