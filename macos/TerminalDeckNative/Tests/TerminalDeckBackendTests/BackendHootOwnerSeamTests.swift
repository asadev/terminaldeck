import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private final class HootConsentTestTime: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 1000
    func read() -> Double { lock.withLock { value } }
    func advance() { lock.withLock { value += 200_000 } }
}
final class BackendHootOwnerSeamTests: XCTestCase, @unchecked Sendable {
    private func wait(_ test: () async -> Bool) async throws {
        for _ in 0..<100 { if await test() { return }; try await Task.sleep(for: .milliseconds(20)) }
        throw NativeRPCError(code: "test-timeout", message: "Hoot binding did not reach the expected state.")
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hoot-owner-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    private func launch(_ root: URL) -> BackendHootChatLaunch {
        var path = URL(fileURLWithPath: #filePath); for _ in 0..<4 { path.deleteLastPathComponent() }
        return .init(command: "/usr/bin/python3", arguments: [path.appendingPathComponent("hootchat/HootFakeRPC.py").path, "codex"],
                     cwd: root.path, environment: [:], setup: .init(cwd: root.path))
    }
    func testRealBrokerIDAndAuthenticatedPhoneOriginBindStructuredAnswersOnce() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let broker = BackendDeckCoreSecurityConsentBroker(ask: { _ in true })
        let store = try BackendHootChatStore(file: root.appendingPathComponent("history.json"), provider: .codex, consent: broker)
        try await store.attach(launch(root)); try await store.initialize()
        _ = try await store.say("form", consentCaller: .init(kind: .remote, tiers: [.read, .act, .alter], deviceID: "phone-one"))
        try await wait { await broker.list().count == 1 }
        let issued = await broker.list()
        let question = try XCTUnwrap(issued.first)
        XCTAssertEqual(question.origin, "device:phone-one")
        XCTAssertEqual(question.tool, "hoot.cli")
        do { try await store.answerBroker(id: "7", allowed: true, by: "device:phone-one"); XCTFail("CLI event ID authorized the phone") } catch {}
        do { try await store.answerBroker(id: question.id, allowed: true, by: "device:other"); XCTFail("Other device answered") } catch {}
        do { try await store.answerBroker(id: question.id, allowed: true, by: "device:phone-one", answers: .object([.init("name", .number(1))])); XCTFail("Bad form settled Core consent") } catch {}
        let stillPending = await broker.list().count; XCTAssertEqual(stillPending, 1)
        try await store.answerBroker(id: question.id, allowed: true, by: "device:phone-one", answers: .object([.init("name", .string("Asad"))]))
        do { try await store.answerBroker(id: question.id, allowed: true, by: "device:phone-one"); XCTFail("Broker decision replayed") } catch {}
        try await wait { await store.isBusy == false }
        await store.stop()
    }
    func testExpiryAndStopCannotReuseBrokerQuestionOrCurrentTurnBinding() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let time = HootConsentTestTime()
        let broker = BackendDeckCoreSecurityConsentBroker(now: { time.read() }, ask: { _ in true })
        let store = try BackendHootChatStore(file: root.appendingPathComponent("history.json"), provider: .codex, consent: broker, consentNow: { time.read() })
        try await store.attach(launch(root)); try await store.initialize(); _ = try await store.say("first")
        try await wait { await broker.list().count == 1 }
        let questions = await broker.list(); let id = try XCTUnwrap(questions.first?.id)
        time.advance()
        do { try await store.answerBroker(id: id, allowed: true, by: "window"); XCTFail("Expired Core question approved") } catch {}
        await store.stop()
        try await wait { await broker.list().isEmpty }
        do { try await store.answerBroker(id: id, allowed: true, by: "window"); XCTFail("Stopped turn remained approvable") } catch {}
    }
    func testProviderPreferenceIsProtectedValidatedAndUsesOwnedSettingStore() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(BackendDeckCoreCatalogueRules.protectedPrefixes.contains { HootProviderPreference.key.hasPrefix($0) })
        XCTAssertEqual(try HootProviderPreference.resolve(.missing), .claude)
        XCTAssertThrowsError(try HootProviderPreference.resolve(.string("shell")))
        let settings = BackendAppSettingsStore(userData: root, writable: true)
        let choice = BackendHootProviderChoice(settings: settings)
        let selected = try await choice.select(.string("gemini"), current: .claude)
        XCTAssertEqual(selected["provider"].string, "gemini"); XCTAssertEqual(selected["restartRequired"].bool, true)
        let reopened = BackendHootProviderChoice(settings: BackendAppSettingsStore(userData: root, writable: true))
        let actual = try await reopened.selected(); XCTAssertEqual(actual, .gemini)
    }
}
