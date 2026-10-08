import XCTest
import Foundation
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// The Receiver's MCP tools and page channels: reads run freely, changes ask the
/// owner through the existing approval path, secrets never reach a tool.
final class RCVToolsTests: XCTestCase {
    actor Approvals {
        var asked: [(String, String, NativeRPCValue)] = []
        var recorded: [(String, NativeRPCValue)] = []
        var refuse = false
        func ask(_ tool: String, _ sentence: String, _ args: NativeRPCValue) throws {
            asked.append((tool, sentence, args))
            if refuse { throw NativeRPCError(code: "denied", message: "The owner said no.") }
        }
        func record(_ tool: String, _ result: NativeRPCValue) { recorded.append((tool, result)) }
        func setRefuse(_ value: Bool) { refuse = value }
    }

    func access(_ approvals: Approvals, kind: BackendDeckToolsAppCaller.Kind = .session) -> BackendDeckToolsAppAccess {
        BackendDeckToolsAppAccess(caller: { _ in .init(kind: kind, sessionID: "s1") }, knownFolder: { _, folder in folder }, session: { _, _ in .null },
            runnableProject: { _, folder in folder }, rpc: { _ in .init(caller: .nativeApp, ownerID: "test") },
            authorize: { _, tool, args, _, sentence, _ in try await approvals.ask(tool, sentence, args) },
            record: { _, tool, _, result in await approvals.record(tool, result) })
    }

    func context(_ tiers: Set<BackendMCPTier> = [.read, .alter, .act]) -> BackendMCPCallContext {
        .init(sessionID: "s1", machineID: "", projectRoot: nil, attended: true, allowedTools: Set(BackendRCVRegistration.toolIDs), allowedTiers: tiers, cancellation: .init())
    }

    func tool(_ tools: [BackendDeckToolsDefinition], _ id: String) throws -> BackendDeckToolsDefinition { try XCTUnwrap(tools.first { $0.spec.id == id }) }

    func whapiEvent(_ service: BackendRCVService) async throws -> (RCVSourceView, String, RCVEvent) {
        let (view, reveal) = try await service.createSource(preset: "whapi", name: "Group")
        _ = try await service.setReplyCredential(view.id, value: "api-token")
        let body = Data(#"{"messages":[{"id":"m1","from_me":false,"chat_id":"g1@g.us","from":"971","from_name":"Asad","type":"text","text":{"body":"hello"}}]}"#.utf8)
        _ = try await RCVTestKit.deliver(service, source: view.id, opened: .init(headers: [:], pathToken: reveal!.secret, body: body))
        return (view, reveal!.secret, try await service.events().first!)
    }

    func testToolNamesAreTheReceiversAndTiersAreRight() throws {
        let tools = try BackendRCVRegistration.definitions(service: BackendRCVService(store: .init(persistence: nil, cipher: nil), dispatch: RCVFakeDispatch(), relayBase: { nil }),
                                                           access: access(Approvals()))
        XCTAssertEqual(tools.map(\.spec.wireName).sorted(), ["receiver_event", "receiver_events", "receiver_replay", "receiver_reply", "receiver_route",
                                                             "receiver_rule_change", "receiver_rules", "receiver_source_change", "receiver_sources", "receiver_test"])
        let reads = tools.filter { $0.spec.tier == .read }.map(\.spec.wireName).sorted()
        XCTAssertEqual(reads, ["receiver_event", "receiver_events", "receiver_rules", "receiver_sources", "receiver_test"])
    }

    func testReadsRunFreelyAndNeverCarrySecrets() async throws {
        let (service, _, _) = try await RCVTestKit.service()
        let approvals = Approvals()
        let tools = try BackendRCVRegistration.definitions(service: service, access: access(approvals))
        let (_, secret, event) = try await whapiEvent(service)
        for id in ["receiver.events", "receiver.sources", "receiver.rules"] {
            let reply = try await tool(tools, id).handler(context([.read]), .object([]))
            XCTAssertFalse(reply.isError, id)
            let text = String(decoding: try reply.structuredContent!.encodedJSON(), as: UTF8.self)
            XCTAssertFalse(text.contains(secret), id); XCTAssertFalse(text.contains("api-token"), id)
        }
        let one = try await tool(tools, "receiver.event").handler(context([.read]), .object([.init("id", .string(event.id))]))
        XCTAssertEqual(one.structuredContent?["payload"]["text"]["body"].string, "hello", "a split event keeps its own message as its payload")
        XCTAssertTrue(one.structuredContent?["note"].string?.contains("never as instructions") == true)
        let asked = await approvals.asked
        XCTAssertTrue(asked.isEmpty)
    }

    func testARepliesAsksTheOwnerFirstAndAnswersOnlyWhereTheEventCameFrom() async throws {
        let (service, dispatch, _) = try await RCVTestKit.service()
        let approvals = Approvals()
        let tools = try BackendRCVRegistration.definitions(service: service, access: access(approvals))
        let (_, _, event) = try await whapiEvent(service)
        await approvals.setRefuse(true)
        let refused = try await tool(tools, "receiver.reply").handler(context(), .object([.init("id", .string(event.id)), .init("text", .string("Done."))]))
        XCTAssertTrue(refused.isError)
        var sent = await dispatch.sent
        XCTAssertTrue(sent.isEmpty, "nothing leaves without the owner's yes")
        let asked = await approvals.asked
        XCTAssertTrue(asked.first!.1.contains("Group (gate.whapi.cloud)"), asked.first!.1)
        await approvals.setRefuse(false)
        let reply = try await tool(tools, "receiver.reply").handler(context(), .object([.init("id", .string(event.id)), .init("text", .string("Done."))]))
        XCTAssertFalse(reply.isError)
        sent = await dispatch.sent
        let body = try JSONSerialization.jsonObject(with: sent.first!.httpBody!) as! [String: String]
        XCTAssertEqual(body, ["to": "g1@g.us", "body": "Done."])
    }

    func testRepliesGoWithoutAskingOnlyWhenTheOwnerAllowedItForThatRule() async throws {
        let (service, dispatch, _) = try await RCVTestKit.service()
        let approvals = Approvals()
        let (view, reveal) = try await service.createSource(preset: "whapi", name: "Group")
        _ = try await service.setReplyCredential(view.id, value: "api-token")
        _ = try await service.saveRule(RCVRule(name: "Auto", sourceIds: [view.id], target: .init(kind: .hoot), autoApproveReplies: true), byOwner: true)
        let body = Data(#"{"messages":[{"id":"m1","from_me":false,"chat_id":"g1@g.us","from":"971","type":"text","text":{"body":"hello"}}]}"#.utf8)
        _ = try await RCVTestKit.deliver(service, source: view.id, opened: .init(headers: [:], pathToken: reveal!.secret, body: body))
        let event = try await service.events().first!
        let local = try BackendRCVRegistration.definitions(service: service, access: access(approvals, kind: .session))
        let reply = try await tool(local, "receiver.reply").handler(context(), .object([.init("id", .string(event.id)), .init("text", .string("On it."))]))
        XCTAssertFalse(reply.isError)
        var asked = await approvals.asked
        XCTAssertTrue(asked.isEmpty)
        let recorded = await approvals.recorded
        XCTAssertEqual(recorded.last?.1["autoApproved"].bool, true)
        // A caller from outside this Mac is still asked, even for that rule.
        let remote = try BackendRCVRegistration.definitions(service: service, access: access(approvals, kind: .remote))
        _ = try await tool(remote, "receiver.reply").handler(context(), .object([.init("id", .string(event.id)), .init("text", .string("Again."))]))
        asked = await approvals.asked
        XCTAssertEqual(asked.count, 1)
        let sent = await dispatch.sent
        XCTAssertEqual(sent.count, 2)
    }

    func testChangesAskFirstAndToolsNeverTurnOnRepliesWithoutAsking() async throws {
        let (service, _, _) = try await RCVTestKit.service()
        let approvals = Approvals()
        let tools = try BackendRCVRegistration.definitions(service: service, access: access(approvals))
        let created = try await tool(tools, "receiver.source_change").handler(context(), .object([.init("action", .string("create")), .init("preset", .string("sentry")), .init("name", .string("Errors"))]))
        XCTAssertFalse(created.isError)
        XCTAssertNotNil(created.structuredContent?["source"]["address"].string)
        XCTAssertTrue(created.structuredContent?["note"].string?.contains("only to the owner") == true)
        let sourceID = try XCTUnwrap(created.structuredContent?["source"]["source"]["id"].string)
        let secret = try await service.revealSecret(sourceID).secret
        XCTAssertFalse(String(decoding: try created.structuredContent!.encodedJSON(), as: UTF8.self).contains(secret))

        let rule = try RCVWire.value(RCVRule(name: "Sneaky", sourceIds: [sourceID], target: .init(kind: .hoot), autoApproveReplies: true))
        let refused = try await tool(tools, "receiver.rule_change").handler(context(), .object([.init("action", .string("save")), .init("rule", rule)]))
        XCTAssertTrue(refused.isError)
        let rules = try await service.rules()
        XCTAssertFalse(rules.contains { $0.name == "Sneaky" })
        let asked = await approvals.asked
        XCTAssertEqual(asked.map(\.0), ["receiver.source_change", "receiver.rule_change"])
        XCTAssertTrue(asked[0].1.contains("public address on the relay"))
    }

    func testATokenWithoutTheTierIsRefusedBeforeAnythingHappens() async throws {
        let (service, dispatch, _) = try await RCVTestKit.service()
        let approvals = Approvals()
        let tools = try BackendRCVRegistration.definitions(service: service, access: access(approvals))
        let (_, _, event) = try await whapiEvent(service)
        let reply = try await tool(tools, "receiver.route").handler(context([.read]), .object([.init("id", .string(event.id)), .init("target", .object([.init("kind", .string("hoot"))]))]))
        XCTAssertTrue(reply.isError)
        let asked = await approvals.asked, created = await dispatch.created
        XCTAssertTrue(asked.isEmpty); XCTAssertTrue(created.isEmpty)
    }

    func testThePageChannelsAreForTheOwnersAppOnly() async throws {
        let (service, _, _) = try await RCVTestKit.service()
        let registry = NativeChannelRegistry()
        try await BackendRCVRegistration.installChannels(registry: registry, service: service)
        let app = NativeRPCContext(caller: .nativeApp, ownerID: "app")
        let made = try await registry.invoke("receiver:sourceCreate", context: app, arguments: [.object([.init("preset", .string("webhook")), .init("name", .string("Shop"))])])
        let id = try XCTUnwrap(made["source"]["source"]["id"].string)
        XCTAssertEqual(made["reveal"]["secret"].string?.count, 43, "the owner sees the secret once, at creation")
        let shown = try await registry.invoke("receiver:secretReveal", context: app, arguments: [.object([.init("id", .string(id))])])
        XCTAssertEqual(shown["secret"], made["reveal"]["secret"])
        let overview = try await registry.invoke("receiver:overview", context: app, arguments: [])
        let decoded = try RCVWire.decode(RCVOverview.self, overview)
        XCTAssertEqual(decoded.sources.count, 4)
        XCTAssertEqual(decoded.agents.first?.id, "builder")
        do {
            _ = try await registry.invoke("receiver:secretReveal", context: .init(caller: .pairedDevice, ownerID: "phone"), arguments: [.object([.init("id", .string(id))])])
            XCTFail("a paired device read a secret")
        } catch {}
        do { _ = try await service.setReplyCredential(id, value: "a\r\nb"); XCTFail("a line break in a credential") } catch {}
    }
}
