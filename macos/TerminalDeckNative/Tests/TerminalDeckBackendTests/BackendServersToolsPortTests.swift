import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("The three curated server tools stay a closed surface")
struct BackendServersToolsPortTests {
    @Test func exactlyThreeCuratedTools() throws { #expect(try BackendServersTools.definitions().map(\.id).sorted() == ["servers.control", "servers.logs", "servers.look"]) }
    @Test func noArbitraryCommandToolNames() throws { for t in try BackendServersTools.definitions() { #expect(t.id.range(of: #"\.(run|exec|shell|command|script|sh|eval|sudo)$"#, options: .regularExpression) == nil) } }
    @Test func noFreeTextCommandArguments() throws { for t in try BackendServersTools.definitions() { for f in t.inputSchema["properties"].fields ?? [] { #expect(f.key.range(of: #"(?i)^(command|cmd|argv|args|script|shell|exec|run|sudo|code|eval|sql|query)$"#, options: .regularExpression) == nil) } } }
    @Test func controlEnumIsDerivedClosedCatalogueWithoutLocalActions() throws {
        let tool = try #require(BackendServersTools.definitions().first { $0.id == "servers.control" })
        #expect(tool.inputSchema["properties"]["action"]["enum"].elements == BackendServersActionID.control.map { .string($0.rawValue) }); #expect(!BackendServersActionID.control.contains(.open)); #expect(!BackendServersActionID.control.contains(.copyAddress)); #expect(!BackendServersActionID.control.contains(.logs))
    }
    @Test func invalidActionRefusesBeforeAnyDialog() async throws {
        let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }
        do { _ = try await BackendServersTools.invoke("servers.control", arguments: .object([.init("serverId", .string("s1")), .init("cardId", .string("service:one.service")), .init("action", .string("rm -rf /"))]), caller: .init(kind: .local, attended: true, context: .init(caller: .internalEngine, ownerID: "local")), room: a.room); Issue.record("Invalid action was accepted") }
        catch { #expect(error.localizedDescription.contains("action must be one of")) }
        #expect(await a.audit.tiers() == [] && a.client.commands == [] && a.dialer.count == 0); await a.stop()
    }
    @Test func toolSourceCannotReachTransportDirectly() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/TerminalDeckBackend/BackendServersTools.swift")
        let source = try String(contentsOf: sources, encoding: .utf8).replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression).replacingOccurrences(of: #"(?m)^\s*//.*$"#, with: "", options: .regularExpression)
        #expect(source.range(of: #"\brun\s*\("#, options: .regularExpression) == nil); #expect(!source.contains("BackendServersConnections"))
    }
    @Test func accountRedactionPreservesShapeAndOtherFacts() throws {
        let view: NativeRPCValue = .object([.init("facts", .object([.init("agents", .object([.init("known", .string("yes")), .init("value", .array([.object([.init("id", .string("claude")), .init("account", .string("me@example.test")), .init("version", .string("2"))])]))])), .init("os", .string("Ubuntu"))]))])
        let safe = BackendServersTools.withoutAccounts(view); #expect(safe["facts"]["agents"]["value"].elements?.first?["account"] == .null); #expect(safe["facts"]["agents"]["value"].elements?.first?["version"].string == "2"); #expect(safe["facts"]["os"] == view["facts"]["os"]); #expect(view["facts"]["agents"]["value"].elements?.first?["account"].string == "me@example.test")
        for wire in [NativeRPCValue.object([]), .object([.init("facts", .object([.init("agents", .object([.init("known", .string("cannot")), .init("why", .string("not asked"))]))]))])] { #expect(BackendServersTools.withoutAccounts(wire) == wire) }
    }
}
