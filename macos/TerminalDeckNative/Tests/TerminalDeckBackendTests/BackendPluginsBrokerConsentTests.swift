import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendPluginsBrokerConsentTests: XCTestCase, @unchecked Sendable {
    private var question: BackendPluginsConsentRequest {
        .init(id: "plugin-a", name: "Plugin A", version: "1.0", hash: "hash-a", capabilities: ["tasks"],
              projects: ["/project"], tools: ["read"], message: "Allow Plugin A?", detail: "Read project tasks.")
    }
    func testPhoneCanAnswerTheSharedQuestionAndASecondQuestionIsRefused() async throws {
        let shown = expectation(description: "question delivered")
        let broker = BackendDeckCoreSecurityConsentBroker(ask: { _ in shown.fulfill(); return true })
        let consent = BackendPluginsBrokerConsent(broker: broker)
        let call = Task { await consent.ask(question) }
        await fulfillment(of: [shown], timeout: 2)
        let pending = await broker.list(), row = try XCTUnwrap(pending.first)
        XCTAssertEqual(pending.count, 1); XCTAssertEqual(row.tool, "plugins.allow")
        XCTAssertEqual(row.arguments["hash"], .string("hash-a"))
        XCTAssertEqual(row.arguments["detail"], .string("Read project tasks."))
        let second = await consent.ask(question)
        XCTAssertFalse(second.granted); XCTAssertEqual(second.reason, "no-approver")
        let outsider = await broker.respond(id: row.id, approved: true, by: "key:other")
        XCTAssertFalse(outsider)
        let accepted = await broker.respond(id: row.id, approved: true, by: "device:phone")
        XCTAssertTrue(accepted)
        let answer = await call.value
        XCTAssertTrue(answer.granted); XCTAssertEqual(answer.reason, "allowed")
    }
    func testShutdownSettlesPendingQuestion() async {
        let shown = expectation(description: "question delivered")
        let broker = BackendDeckCoreSecurityConsentBroker(ask: { _ in shown.fulfill(); return true })
        let consent = BackendPluginsBrokerConsent(broker: broker)
        let call = Task { await consent.ask(question) }
        await fulfillment(of: [shown], timeout: 2)
        await consent.shutdown()
        let answer = await call.value, pending = await broker.list(), next = await consent.ask(question)
        XCTAssertFalse(answer.granted); XCTAssertEqual(answer.reason, "shutting-down")
        XCTAssertTrue(pending.isEmpty); XCTAssertEqual(next.reason, "shutting-down")
    }
    func testNoApproverAndTimeoutRefuse() async {
        let missing = BackendPluginsBrokerConsent(broker: BackendDeckCoreSecurityConsentBroker(ask: { _ in false }))
        let no = await missing.ask(question)
        XCTAssertFalse(no.granted); XCTAssertEqual(no.reason, "no-approver")
        let consent = BackendPluginsBrokerConsent(broker: BackendDeckCoreSecurityConsentBroker(timeoutMilliseconds: 1, ask: { _ in true }))
        let expired = await consent.ask(question)
        XCTAssertFalse(expired.granted); XCTAssertEqual(expired.reason, "timeout")
    }
    func testBackendPresentationBoundary() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["BackendNodelessCertificateDialog", "BackendPluginsChannels", "BackendPluginsBrokerConsent", "BackendS3FillFreeStandingConsent", "BackendS3FillResidentPresence", "BackendHootScreenMonitor"] {
            let source = try String(contentsOf: package.appendingPathComponent("Sources/TerminalDeckBackend/" + name + ".swift"), encoding: .utf8)
            for forbidden in ["import AppKit", "NSAlert", "NSPanel", "NSScreen", "NSStatusBar", "runModal"] {
                XCTAssertFalse(source.contains(forbidden), name + " must leave presentation to the app: " + forbidden)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.appendingPathComponent("Sources/TerminalDeckBackend/BackendHootPanelBindings.swift").path))
    }
}
