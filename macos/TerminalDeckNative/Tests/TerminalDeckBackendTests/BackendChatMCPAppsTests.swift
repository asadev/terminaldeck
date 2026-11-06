import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor MCPAppTrial {
    var approved = false
    var calls = 0
    var consentRequests = 0
    var sourcePresent = true
    var resourceServer: String?
    func approve(_ value: Bool) { approved = value }
    func invalidate() { sourcePresent = false }
    func consent() -> Bool { consentRequests += 1; return approved }
    func called() { calls += 1 }
    func readResource(_ id: String) { resourceServer = id }
    func counts() -> (Int, Int) { (calls, consentRequests) }
    func rows() throws -> [HootChatRow] {
        guard sourcePresent else { return [] }
        return HootChatProjection.rows([HootChatEvent(conversationID: "c", turnID: "turn", sequence: 1, provider: .claude,
            record: .init(.toolCall, id: "call", value: .object([.init("name", .string("mcp__weather__forecast")), .init("input", .object([.init("place", .string("Dubai"))])), .init("finished", .bool(true)),
                .init("output", .object([.init("content", .array([])), .init("structuredContent", .object([.init("degrees", .number(30))]))]))])))])
    }
}
private let appTool = NativeRPCValue.object([.init("name", .string("forecast")), .init("_meta", .object([.init("ui", .object([.init("resourceUri", .string("ui://weather/forecast"))]))]))])
private func appService(_ trial: MCPAppTrial, consent: BackendChatMCPApps.Consent? = nil) -> BackendChatMCPApps {
    BackendChatMCPApps(read: { _ in .init(rows: try await trial.rows(), project: "/scratch", provider: "claude") },
        servers: { _ in [.object([.init("id", .string("user:weather")), .init("name", .string("weather"))])] },
        inventory: { id, _, _, _ in
            #expect(id == "user:weather")
            return .object([.init("tools", .array([appTool]))])
        }, resource: { id, _, uri, _ in
            await trial.readResource(id)
            return .object([.init("contents", .array([.object([.init("uri", .string(uri)), .init("mimeType", .string("text/html;profile=mcp-app")), .init("text", .string("<h1>Forecast</h1>"))])]))])
        }, call: { _, _, _, _ in await trial.called(); return .object([.init("ok", .bool(true)), .init("result", .object([.init("content", .array([]))]))]) },
        consent: consent ?? { _, _, _ in await trial.consent() }, openLink: { _ in true })
}
private func appRequest(_ method: String, _ params: NativeRPCValue = .object([])) -> NativeRPCValue {
    .object([.init("jsonrpc", .string("2.0")), .init("id", .number(1)), .init("method", .string(method)), .init("params", params)])
}
private func initializeApp(_ service: BackendChatMCPApps, view: String = "default") async {
    _ = await service.bridge(session: "s", rowID: "turn:call", message: appRequest("ui/initialize", .object([.init("protocolVersion", .string("2026-01-26"))])), viewID: view)
    _ = await service.bridge(session: "s", rowID: "turn:call", message: appRequest("ui/notifications/initialized").removing("id"), viewID: view)
}
@Test func backendChatMCPAppsReadsOnlyTheRecordedServer() async throws {
    let trial = MCPAppTrial(), service = appService(trial)
    let document = try await service.document(session: "s", rowID: "turn:call")
    #expect(document["html"].string == "<h1>Forecast</h1>")
    #expect(await trial.resourceServer == "user:weather")
    #expect(document["result"]["structuredContent"]["degrees"].number == 30)
    #expect(try await service.document(session: "s", rowID: "forged") == .null)
}
@Test func backendChatMCPAppsRequiresExactResourceMimeAndURI() throws {
    let bad = NativeRPCValue.object([.init("contents", .array([.object([.init("uri", .string("ui://other")), .init("mimeType", .string("text/html")), .init("text", .string("bad"))])]))])
    #expect(throws: NativeRPCError.self) { try BackendChatMCPApps.html(bad, uri: "ui://weather/forecast") }
    #expect(BackendChatMCPApps.uiURI(appTool) == "ui://weather/forecast")
    #expect(BackendChatMCPApps.uiURI(appTool.setting("_meta", .object([]))) == nil)
}
@Test func backendChatMCPAppsInitializesBeforeSendingInputAndFullResult() async throws {
    let service = appService(MCPAppTrial())
    let initialized = await service.bridge(session: "s", rowID: "turn:call", message: appRequest("ui/initialize", .object([.init("protocolVersion", .string("2026-01-26"))])))
    #expect(initialized.elements?.count == 1)
    #expect(initialized.elements?.first?["result"]["hostCapabilities"]["serverTools"].fields != nil)
    let messages = await service.bridge(session: "s", rowID: "turn:call", message: appRequest("ui/notifications/initialized"))
    #expect(messages.elements?.map { $0["method"].string ?? "" } == ["ui/notifications/tool-input", "ui/notifications/tool-result"])
    #expect(messages.elements?.first?["params"]["arguments"]["place"].string == "Dubai")
}
@Test func backendChatMCPAppsNeverRunsDeniedOrUnknownTools() async throws {
    let trial = MCPAppTrial(), service = appService(trial)
    await initializeApp(service)
    let denied = await service.bridge(session: "s", rowID: "turn:call", message: appRequest("tools/call", .object([.init("name", .string("forecast"))])))
    #expect(denied.elements?.first?["error"].fields != nil)
    #expect((await trial.counts()).0 == 0)
    await trial.approve(true)
    let unknown = await service.bridge(session: "s", rowID: "turn:call", message: appRequest("tools/call", .object([.init("name", .string("delete_everything"))])))
    #expect(unknown.elements?.first?["error"].fields != nil)
    #expect((await trial.counts()).0 == 0)
}
@Test func backendChatMCPAppsRunsApprovedCallsAndRechecksSource() async throws {
    let trial = MCPAppTrial(), service = appService(trial)
    await trial.approve(true)
    await initializeApp(service)
    let answer = await service.bridge(session: "s", rowID: "turn:call", message: appRequest("tools/call", .object([.init("name", .string("forecast"))])))
    #expect(answer.elements?.first?["result"]["content"].elements != nil)
    #expect((await trial.counts()).0 == 1)
    let stale = appService(trial, consent: { _, _, _ in await trial.invalidate(); return true })
    await initializeApp(stale)
    let blocked = await stale.bridge(session: "s", rowID: "turn:call", message: appRequest("tools/call", .object([.init("name", .string("forecast"))])))
    #expect(blocked.elements?.first?["error"].fields != nil)
    #expect((await trial.counts()).0 == 1)
}
@Test func backendChatMCPAppsRefusesFileLinksAndRequiresLinkConsent() async throws {
    let trial = MCPAppTrial(), service = appService(trial)
    await initializeApp(service)
    let file = await service.bridge(session: "s", rowID: "turn:call", message: appRequest("ui/open-link", .object([.init("url", .string("file:///private"))])))
    #expect(file.elements?.first?["result"]["isError"].bool == true)
    #expect((await trial.counts()).1 == 0)
    let denied = await service.bridge(session: "s", rowID: "turn:call", message: appRequest("ui/open-link", .object([.init("url", .string("https://example.com"))])))
    #expect(denied.elements?.first?["result"]["isError"].bool == true)
    #expect((await trial.counts()).1 == 1)
}
@Test func backendChatMCPAppsPhoneFramesKeepRowAndMessageAndRejectForgedShape() throws {
    let request = NativeRPCValue.object([.init("t", .string("chats.app.bridge")), .init("rid", .string("r")), .init("id", .string("s")), .init("rowId", .string("turn:call")), .init("message", appRequest("ping"))])
    guard case .message(let frame) = BackendRemoteProtocol.parseClientMessage(request.compact) else { Issue.record("The app request did not parse"); return }
    #expect(frame["rowId"].string == "turn:call")
    #expect(frame["message"]["method"].string == "ping")
    guard case .refused = BackendRemoteProtocol.parseClientMessage(request.setting("message", .string("forged")).compact) else { Issue.record("A forged bridge message was accepted"); return }
    let reply = try BackendRemoteServerMessage(.chatsAppResult, fields: [.init("rid", .string("r")), .init("id", .string("s")), .init("rowId", .string("turn:call")), .init("messages", .array([]))])
    #expect(reply.kind.rawValue == "chats.app.result")
}

@Test func backendChatMCPAppsRechecksPhoneGrantBeforeTheServerCall() async throws {
    let trial = MCPAppTrial()
    let service = appService(trial, consent: { _, _, _ in await trial.invalidate(); return true })
    await initializeApp(service)
    let gate: @Sendable () async throws -> Void = {
        let rows = try await trial.rows()
        guard !rows.isEmpty else { throw NativeRPCError(code: "access-denied", message: "The phone grant was revoked.") }
    }
    let answer = await BackendChatMCPApps.$phoneAccessCheck.withValue(gate) {
        await service.bridge(session: "s", rowID: "turn:call", message: appRequest("tools/call", .object([.init("name", .string("forecast"))])))
    }
    #expect(answer.elements?.first?["error"]["message"].string == "The phone grant was revoked.")
    #expect((await trial.counts()).0 == 0)
}

@Test func backendChatMCPAppsBlocksCallsUntilEachViewCompletesHandshake() async throws {
    let trial = MCPAppTrial(), service = appService(trial)
    await trial.approve(true)
    let call = appRequest("tools/call", .object([.init("name", .string("forecast"))]))
    let blocked = await service.bridge(session: "s", rowID: "turn:call", message: call, viewID: "first")
    #expect(blocked.elements?.first?["error"].fields != nil)
    #expect((await trial.counts()).1 == 0)
    _ = await service.bridge(session: "s", rowID: "turn:call", message: appRequest("ui/initialize", .object([.init("protocolVersion", .string("2026-01-26"))])), viewID: "first")
    let incomplete = await service.bridge(session: "s", rowID: "turn:call", message: call, viewID: "first")
    #expect(incomplete.elements?.first?["error"].fields != nil)
    let input = await service.bridge(session: "s", rowID: "turn:call", message: appRequest("ui/notifications/initialized").removing("id"), viewID: "first")
    #expect(input.elements?.count == 2)
    let duplicate = await service.bridge(session: "s", rowID: "turn:call", message: appRequest("ui/notifications/initialized").removing("id"), viewID: "first")
    #expect(duplicate.elements?.isEmpty == true)
    let other = await service.bridge(session: "s", rowID: "turn:call", message: call, viewID: "other")
    #expect(other.elements?.first?["error"].fields != nil)
    #expect((await trial.counts()).0 == 0)
    let accepted = await service.bridge(session: "s", rowID: "turn:call", message: call, viewID: "first")
    #expect(accepted.elements?.first?["result"].fields != nil)
    #expect((await trial.counts()).0 == 1)
}

@Test func backendChatMCPAppsPagesWholeEnvelopesWithinThePhoneFrameLimit() throws {
    let original = NativeRPCValue.object([.init("html", .string(String(repeating: "<div>📈</div>", count: 12_000))),
        .init("input", .object([.init("large", .string(String(repeating: "x", count: 50_000)))]))])
    let bytes = try original.encodedJSON()
    var collected = Data(), offset = 0
    while true {
        let page = try BackendChatMCPApps.transferPage(bytes, kind: "app", id: "document", offset: offset)
        #expect(page.compact.utf8.count < 48_000)
        #expect(page["app"] == .null)
        #expect(page["total"].number == Double(bytes.count))
        collected.append(try #require(page["documentChunk"].string.flatMap { Data(base64Encoded: $0) }))
        guard let next = page["nextOffset"].number else { break }
        #expect(next > Double(offset)); offset = Int(next)
    }
    #expect(try NativeRPCValue.parseJSON(collected) == original)
}

@Test func backendChatMCPAppsKeepsCodexServerIdentityThroughItsRealDecoder() throws {
    var decoder = HootChatDecoder(provider: .codex)
    let item = NativeRPCValue.object([.init("id", .string("call")), .init("type", .string("mcp_tool_call")),
        .init("server", .string("weather")), .init("tool", .string("forecast")), .init("arguments", .object([.init("place", .string("Dubai"))])),
        .init("status", .string("completed")), .init("result", .object([.init("content", .array([]))]))])
    let records = try decoder.decode(.object([.init("type", .string("item.completed")), .init("item", item)]))
    let events = records.enumerated().map { HootChatEvent(conversationID: "c", turnID: "t", sequence: $0.offset + 1, provider: .codex, record: $0.element) }
    let row = try #require(HootChatProjection.rows(events).first)
    let identity = try #require(BackendChatMCPApps.toolIdentity(row))
    #expect(identity.server == "weather" && identity.tool == "forecast")
    #expect(identity.input["place"].string == "Dubai")
}

@Test func backendChatMCPAppsRefusesArgumentsThatImpersonateServerMetadata() throws {
    var decoder = HootChatDecoder(provider: .gemini)
    let record = NativeRPCValue.object([.init("type", .string("tool_use")), .init("tool_id", .string("call")), .init("tool_name", .string("generic_tool")),
        .init("parameters", .object([.init("server", .string("weather")), .init("tool", .string("forecast"))]))])
    let records = try decoder.decode(record)
    let row = try #require(HootChatProjection.rows(records.enumerated().map {
        HootChatEvent(conversationID: "c", turnID: "t", sequence: $0.offset + 1, provider: .gemini, record: $0.element)
    }).first)
    #expect(BackendChatMCPApps.toolIdentity(row) == nil)
}

@Test func backendChatMCPAppsRechecksSourceAfterOpenLinkConsent() async throws {
    let trial = MCPAppTrial(), service = appService(trial, consent: { _, _, _ in await trial.invalidate(); return true })
    await initializeApp(service)
    let answer = await service.bridge(session: "s", rowID: "turn:call", message: appRequest("ui/open-link", .object([.init("url", .string("https://example.com"))])))
    #expect(answer.elements?.first?["error"].fields != nil)
}

private func namespacedAppService(_ trial: MCPAppTrial, tools: [String: [String]]) -> BackendChatMCPApps {
    BackendChatMCPApps(read: { _ in
        let event = HootChatEvent(conversationID: "c", turnID: "turn", sequence: 1, provider: .claude,
            record: .init(.toolCall, id: "call", value: .object([
                .init("name", .string("mcp__foo__bar__baz")), .init("input", .object([])),
                .init("finished", .bool(true)), .init("output", .object([.init("content", .array([]))]))])))
        return .init(rows: HootChatProjection.rows([event]), project: "/scratch", provider: "claude")
    }, servers: { _ in
        tools.keys.sorted().map { name in .object([.init("id", .string("user:" + name)), .init("name", .string(name))]) }
    }, inventory: { id, _, _, _ in
        let name = String(id.dropFirst("user:".count))
        return .object([.init("tools", .array((tools[name] ?? []).map { appTool.setting("name", .string($0)) }))])
    }, resource: { id, _, uri, _ in
        await trial.readResource(id)
        return .object([.init("contents", .array([.object([
            .init("uri", .string(uri)), .init("mimeType", .string("text/html;profile=mcp-app")),
            .init("text", .string("<h1>Exact server</h1>"))])]))])
    }, call: { _, _, _, _ in .null }, consent: { _, _, _ in false }, openLink: { _ in false })
}

@Test func backendChatMCPAppsResolvesUnderscoresInTheConfiguredServerName() async throws {
    let trial = MCPAppTrial(), service = namespacedAppService(trial, tools: ["unrelated": [], "foo__bar": ["baz"]])
    #expect(try await service.document(session: "s", rowID: "turn:call")["html"].string != nil)
    #expect(await trial.resourceServer == "user:foo__bar")
}

@Test func backendChatMCPAppsRefusesAmbiguousServerAndToolNamespaces() async throws {
    let trial = MCPAppTrial(), service = namespacedAppService(trial, tools: ["foo": ["bar__baz"], "foo__bar": ["baz"]])
    #expect(try await service.document(session: "s", rowID: "turn:call") == .null)
    #expect(await trial.resourceServer == nil)
}

@Test func backendChatMCPAppsRefusesNamespaceAmbiguityEvenWhenOnlyOneInventoryOffersTheTool() async throws {
    let trial = MCPAppTrial(), service = namespacedAppService(trial, tools: ["foo": ["bar__baz"], "foo__bar": ["unrelated"]])
    #expect(try await service.document(session: "s", rowID: "turn:call") == .null)
    #expect(await trial.resourceServer == nil)
}

private func richMessageService(_ text: String) -> BackendChatMCPApps {
    BackendChatMCPApps(read: { session in
        let events: [HootChatEvent] = session == "source" ? [HootChatEvent(conversationID: "c", turnID: "turn", sequence: 1, provider: .claude,
            record: .text(.message, id: "reply", text))] : []
        return .init(rows: HootChatProjection.rows(events), project: "/scratch", provider: "claude")
    }, servers: { _ in [] }, inventory: { _, _, _, _ in .null }, resource: { _, _, _, _ in .null },
        call: { _, _, _, _ in .null }, consent: { _, _, _ in false }, openLink: { _ in false })
}

@Test func backendChatMCPAppsPagesLargeRichMessageSourceAndRenderedBlocks() async throws {
    let source = "# Wide reply\n\n```visual\n<div>" + String(repeating: "📈", count: 12_000) + "</div>\n```\n"
    let service = richMessageService(source)
    var page = try await service.phoneDocument(session: "source", rowID: "turn:reply", owner: "phone")
    let documentID = try #require(page["documentId"].string)
    var bytes = Data()
    while true {
        #expect(page.compact.utf8.count < 48_000)
        bytes.append(try #require(page["documentChunk"].string.flatMap { Data(base64Encoded: $0) }))
        guard let next = page["nextOffset"].number else { break }
        page = try await service.phoneDocument(session: "source", rowID: "turn:reply", owner: "phone", offset: Int(next), documentID: documentID)
    }
    let full = try NativeRPCValue.parseJSON(bytes)
    #expect(full["type"].string == "richMessage" && full["rowId"].string == "turn:reply")
    #expect(full["text"].string == source)
    #expect(full["blocks"] == ChatMarkdown.renderedBlocks(source))
}

@Test func backendChatMCPAppsRefusesRichMessageOutsideItsSourceAndItsBridge() async throws {
    let service = richMessageService("# Private source")
    do {
        _ = try await service.phoneDocument(session: "other", rowID: "turn:reply", owner: "phone")
        Issue.record("An unrelated source returned this message.")
    } catch let error as NativeRPCError { #expect(error.code == "stale") }
    let bridge = await service.bridge(session: "source", rowID: "turn:reply", message: appRequest("ui/initialize", .object([.init("protocolVersion", .string("2026-01-26"))])))
    #expect(bridge.elements?.first?["error"].fields != nil)
}

private func provenanceRows(_ value: NativeRPCValue, provider: HootChatProvider = .claude) -> [HootChatRow] {
    HootChatProjection.rows([HootChatEvent(conversationID: "c", turnID: "t", sequence: 1, provider: provider,
        record: .init(.toolCall, id: "call", value: value.setting("finished", .bool(true)).setting("output", .object([]))))])
}

@Test func backendChatMCPAppsArgumentsCannotOverrideTheRecordedNamespace() throws {
    let value = NativeRPCValue.object([.init("name", .string("mcp__A__shared")), .init("input", .object([
        .init("type", .string("mcp_tool_call")), .init("server", .string("B")), .init("tool", .string("shared")),
        .init("arguments", .object([.init("private", .string("call input"))]))]))])
    let row = try #require(provenanceRows(value).first)
    let identity = try #require(BackendChatMCPApps.toolIdentity(row))
    #expect(identity.server.isEmpty && identity.tool == "mcp__A__shared")
    #expect(identity.input["server"].string == "B")
    let ordinary = value.setting("name", .string("ordinary_tool"))
    let ordinaryRow = try #require(provenanceRows(ordinary).first)
    #expect(BackendChatMCPApps.toolIdentity(ordinaryRow) == nil)
}

@Test func backendChatMCPAppsRejectsConflictingTypedMetadataAndAmbiguousConfiguredServers() async throws {
    let typed = NativeRPCValue.object([.init("name", .string("mcp__A__forecast")), .init("input", .object([])),
        .init("mcpCall", .object([.init("server", .string("B")), .init("tool", .string("forecast"))]))])
    let service = BackendChatMCPApps(read: { _ in .init(rows: provenanceRows(typed), project: "/scratch", provider: "claude") },
        servers: { _ in [.object([.init("id", .string("user:B")), .init("name", .string("B"))])] },
        inventory: { _, _, _, _ in Issue.record("Conflicting provenance reached a server"); return .null },
        resource: { _, _, _, _ in Issue.record("Conflicting provenance exposed source data"); return .null },
        call: { _, _, _, _ in .null }, consent: { _, _, _ in false }, openLink: { _ in false })
    #expect(try await service.document(session: "s", rowID: "t:call") == .null)
    let ambiguous = BackendChatMCPApps(read: { _ in .init(rows: provenanceRows(typed.setting("name", .string("forecast"))), project: "/scratch", provider: "claude") },
        servers: { _ in ["user:B", "project:B"].map { .object([.init("id", .string($0)), .init("name", .string("B"))]) } },
        inventory: { _, _, _, _ in Issue.record("Ambiguous server reached inventory"); return .null }, resource: { _, _, _, _ in .null },
        call: { _, _, _, _ in .null }, consent: { _, _, _ in false }, openLink: { _ in false })
    #expect(try await ambiguous.document(session: "s", rowID: "t:call") == .null)
}

@Test func backendChatMCPAppsTypedProvenanceRejectsConflictingProviderAliases() {
    let item = NativeRPCValue.object([.init("type", .string("mcpToolCall")), .init("server", .string("A")),
        .init("serverName", .string("B")), .init("tool", .string("forecast"))])
    #expect(HootChatMCPProvenance.record(item)["invalid"].bool == true)
    #expect(HootChatMCPProvenance.record(item.setting("type", .string("ordinary_tool"))) == .null)
}

@Test func backendChatMCPAppsSpoofedArgumentsStillLoadOnlyRecordedServerA() async throws {
    let trial = MCPAppTrial()
    let input = NativeRPCValue.object([.init("type", .string("mcpToolCall")), .init("server", .string("B")), .init("tool", .string("forecast")), .init("arguments", .object([]))])
    let row = NativeRPCValue.object([.init("name", .string("mcp__A__forecast")), .init("input", input)])
    let service = BackendChatMCPApps(read: { _ in .init(rows: provenanceRows(row), project: "/scratch", provider: "claude") },
        servers: { _ in ["A", "B"].map { .object([.init("id", .string("user:" + $0)), .init("name", .string($0))]) } },
        inventory: { id, _, _, _ in
            #expect(id == "user:A")
            return .object([.init("tools", .array([appTool]))])
        }, resource: { id, _, uri, _ in
            await trial.readResource(id)
            return .object([.init("contents", .array([.object([.init("uri", .string(uri)), .init("mimeType", .string("text/html;profile=mcp-app")), .init("text", .string("<h1>A</h1>"))])]))])
        }, call: { _, _, _, _ in .null }, consent: { _, _, _ in false }, openLink: { _ in false })
    let app = try await service.document(session: "s", rowID: "t:call")
    #expect(await trial.resourceServer == "user:A")
    #expect(app["html"].string == "<h1>A</h1>" && app["input"] == input)
}

@Test func backendChatMCPAppsRefusesDuplicateNamedServersBeforeReadingEitherInventory() async throws {
    let trial = MCPAppTrial()
    let service = BackendChatMCPApps(read: { _ in .init(rows: try await trial.rows(), project: "/scratch", provider: "claude") },
        servers: { _ in ["user:weather", "project:weather"].map { .object([.init("id", .string($0)), .init("name", .string("weather"))]) } },
        inventory: { id, _, _, _ in
            Issue.record("Ambiguous server reached inventory: \(id)")
            return .object([.init("tools", .array(id == "user:weather" ? [appTool] : []))])
        }, resource: { id, _, _, _ in await trial.readResource(id); return .null },
        call: { _, _, _, _ in .null }, consent: { _, _, _ in false }, openLink: { _ in false })
    #expect(try await service.document(session: "s", rowID: "turn:call") == .null)
    #expect(await trial.resourceServer == nil)
}
