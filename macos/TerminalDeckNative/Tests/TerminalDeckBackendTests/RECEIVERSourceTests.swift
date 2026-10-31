import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// Receiver #112 focused regression draft. Uses only the existing in-memory
/// store and RCVFakeDispatch; no relay socket, credentials or AI calls.
final class RECEIVERSourceTests: XCTestCase {
    private let sourceID = "terminaldeck.servers"
    private let sample = #"{"kind":"server.unreachable","severity":"error","title":"Example server stopped","text":"Fixture only","id":"receiver-test"}"#

    override func setUpWithError() throws {
        try super.setUpWithError()
        let env = ProcessInfo.processInfo.environment
        let lanes = (env["TD_WIP"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard lanes.contains("RECEIVER") || env["RECEIVER_FOCUSED_BACKEND"] == "1" else {
            throw XCTSkip("WIP RECEIVER: enable RECEIVER_FOCUSED_BACKEND=1 for the fake-only source checks.")
        }
    }

    func testBuiltInPauseDropsEventsAndResumeUsesTheOwnersRule() async throws {
        let (service, dispatch, _) = try await RCVTestKit.service()
        let sources = try await service.sources()
        var source = try XCTUnwrap(sources.first { $0.id == sourceID }).source
        _ = try await service.saveRule(.init(name: "Send server events", sourceIds: [source.id], target: .init(kind: .session, id: "s1")), byOwner: true)
        source.enabled = false
        let paused = try await service.saveSource(source)
        XCTAssertEqual(RCVPresentation.state(paused).word, "Paused")
        await service.post(internal: source.id, .init(kind: "server.unreachable", title: "Paused", id: "paused"))
        let before = try await service.events(sourceID: source.id)
        let beforeTyped = await dispatch.typed
        XCTAssertTrue(before.isEmpty)
        XCTAssertTrue(beforeTyped.isEmpty)

        source.enabled = true
        let resumed = try await service.saveSource(source)
        XCTAssertTrue(resumed.active)
        XCTAssertNil(resumed.address)
        await service.post(internal: source.id, .init(kind: "server.unreachable", title: "Resumed", id: "resumed"))
        let after = try await service.events(sourceID: source.id)
        let afterTyped = await dispatch.typed
        XCTAssertEqual(after.map(\.title), ["Resumed"])
        XCTAssertEqual(after.first?.status, .delivered)
        XCTAssertEqual(afterTyped.map { $0.0 }, ["s1"])
    }

    func testBuiltInSaveKeepsIdentityWhileAcceptingProjectAndEventChoices() async throws {
        let (service, dispatch, _) = try await RCVTestKit.service()
        let sources = try await service.sources()
        let original = try XCTUnwrap(sources.first { $0.id == sourceID }).source
        var edited = original
        edited.name = "Server events"
        edited.projectScope = .project
        edited.projectID = "imatch"
        edited.type = "Server alert"
        edited.origin = .relay
        edited.preset = "github"
        edited.createdAt = 0
        edited.auth = .init(scheme: .basic, basicUser: "fixture")
        edited.reply = .init(url: "https://example.invalid/reply")
        edited.mapping.ignore = [.init("kind", .equals, "server.healthy")]
        let saved = try await service.saveSource(edited)
        XCTAssertEqual(saved.source.name, "Server events")
        XCTAssertEqual(saved.source.projectID, "imatch")
        XCTAssertEqual(saved.source.effectiveProjectScope, .project)
        XCTAssertEqual(saved.source.type, "Server alert")
        XCTAssertEqual(saved.source.mapping.ignore, edited.mapping.ignore)
        XCTAssertEqual(saved.source.origin, original.origin)
        XCTAssertEqual(saved.source.preset, original.preset)
        XCTAssertEqual(saved.source.createdAt, original.createdAt)
        XCTAssertEqual(saved.source.auth, original.auth)
        XCTAssertNil(saved.source.reply)
        XCTAssertNil(saved.address)

        await service.post(internal: original.id, .init(kind: "server.healthy", title: "Ignored", id: "ignored"))
        let events = try await service.events(sourceID: original.id)
        let created = await dispatch.created
        XCTAssertEqual(events.first?.status, .ignored)
        XCTAssertTrue(created.isEmpty)
        do {
            try await service.deleteSource(original.id)
            XCTFail("A built-in source must be paused, never deleted.")
        } catch let error as NativeRPCError {
            XCTAssertTrue(error.message.contains("paused but not deleted"), error.message)
        }
    }

    func testSourceValidationIsAtomicAndAllGenericTypesPersist() async throws {
        let (service, _, _) = try await RCVTestKit.service()
        let sources = try await service.sources()
        let original = try XCTUnwrap(sources.first { $0.id == sourceID }).source
        var invalid = original
        invalid.name = ""
        invalid.enabled = false
        invalid.projectID = "other-project"
        do {
            _ = try await service.saveSource(invalid)
            XCTFail("An empty source name must fail.")
        } catch let error as NativeRPCError {
            XCTAssertEqual(error.message, "Give the source a name of up to 80 characters.")
        }
        let after = try await service.sources()
        XCTAssertEqual(after.first { $0.id == original.id }?.source, original)

        let labels = ["Webhook (any JSON)", "WhatsApp gateway", "Code host", "Error tracker", "CRM",
                      "Uptime monitor", "Server alert", "Chat app", "Container host"]
        for (index, label) in labels.enumerated() {
            let created = try await BackendRCVRegistration.channel("sourceCreate", .object([
                .init("preset", .string("webhook")), .init("name", .string("Fixture \(index)")),
                .init("type", .string(label)), .init("projectId", .string("imatch")), .init("projectScope", .string("project"))
            ]), service: service)
            let view = try RCVWire.decode(RCVSourceView.self, created["source"])
            XCTAssertEqual(view.source.type, label)
            XCTAssertEqual(view.source.projectID, "imatch")
            XCTAssertEqual(view.source.effectiveProjectScope, .project)
            XCTAssertEqual(view.source.preset, "webhook", "Generic type is separate from the sender preset.")
            var edited = view.source
            let nextLabel = labels[(index + 1) % labels.count]
            edited.type = nextLabel
            let saved = try await service.saveSource(edited)
            XCTAssertEqual(saved.source.type, nextLabel)
            XCTAssertEqual(saved.source.preset, view.source.preset)
            XCTAssertEqual(try BackendRCVRegistration.sourceSummary(saved)["source"]["type"].string, nextLabel,
                           "The MCP source summary carries the persisted generic category.")
        }
    }

    func testSourceTestUsesSavedRulesWithoutSpendingLimitsOrSendingAnything() async throws {
        let (service, dispatch, _) = try await RCVTestKit.service()
        _ = try await service.saveRule(.init(name: "Fixture errors", sourceIds: [sourceID], target: .init(kind: .hoot), perMinute: 1, dedupeMinutes: 10), byOwner: true)
        let store = await service.storeForTests()
        let before = try await store.read()
        for _ in 0..<3 {
            let (decision, event) = try await service.test(rule: nil, eventID: nil, sourceID: sourceID, sample: sample)
            XCTAssertEqual(decision.status, .delivered)
            XCTAssertEqual(decision.target?.kind, .hoot)
            XCTAssertEqual(event.title, "Example server stopped")
        }
        let after = try await store.read()
        let created = await dispatch.created
        let typed = await dispatch.typed
        let sent = await dispatch.sent
        let comments = await dispatch.comments
        XCTAssertEqual(after, before, "Source testing must keep the whole saved state unchanged.")
        XCTAssertTrue(created.isEmpty)
        XCTAssertTrue(typed.isEmpty)
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(comments.isEmpty)
    }

    func testSourceTestChannelReturnsTheDryRunAndRejectsMissingSourcesClearly() async throws {
        let (service, dispatch, _) = try await RCVTestKit.service()
        _ = try await service.saveRule(.init(name: "Fixture session", sourceIds: [sourceID], target: .init(kind: .session, id: "s1")), byOwner: true)
        let answer = try await BackendRCVRegistration.channel("test", .object([.init("sourceId", .string(sourceID)), .init("sample", .string(sample))]), service: service)
        let decision = try RCVWire.decode(RCVDecision.self, answer["decision"])
        XCTAssertEqual(decision.status, .delivered)
        XCTAssertEqual(decision.target?.id, "s1")
        let typed = await dispatch.typed
        let events = try await service.events()
        XCTAssertTrue(typed.isEmpty)
        XCTAssertTrue(events.isEmpty)
        do {
            _ = try await BackendRCVRegistration.channel("test", .object([.init("sourceId", .string("missing")), .init("sample", .string(sample))]), service: service)
            XCTFail("A removed source must not produce a successful test.")
        } catch let error as NativeRPCError {
            XCTAssertEqual(error.message, "Choose a source or an event to test with.")
        }
    }
}
