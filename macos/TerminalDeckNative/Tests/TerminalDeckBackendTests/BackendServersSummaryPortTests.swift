import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Stored server summary and server-owned consequence words")
struct BackendServersSummaryPortTests {
    private var sources: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources") }
    private let fragments = ["It’ll be running again in a few seconds.", "It’ll be offline for about five seconds while it starts again.", "It’ll be off until you start it again", "We’ll keep the current version so you can go back.", "We’ll remember where it is now so you can go back.", "Copy everything in", "Nothing on the server changes.", "This can take a minute or two."]
    private func store() -> (URL, BackendServersStore) { let dir = FileManager.default.temporaryDirectory.appendingPathComponent("servers-summary-port-" + UUID().uuidString); return (dir, BackendServersStore(dataRoot: dir, policy: .init(mayRead: true, mayWrite: true))) }
    private func whereLine(_ s: BackendServersSummary) throws -> String { let json = CodingAIJSON.parse(String(decoding: try s.wireValue.encodedJSON(), as: UTF8.self)); return try #require(CodingAIServer.parseList(.array([json])).first).whereLine }
    @Test func typedPortCrossesRealStoreAndDrawnLine() throws {
        let (dir, store) = store(); defer { try? FileManager.default.removeItem(at: dir) }
        let row = try store.add(.init(name: "office pc", address: "192.0.2.11", port: 2222, username: "admin")), s = BackendServersSummary(row)
        #expect(row.port == 2222 && s.port == 2222); #expect(try whereLine(s) == "admin at 192.0.2.11:2222")
        let addressOnly = BackendServersSummary(.init(id: s.id, name: s.name, address: s.address, port: s.port, username: "")); #expect(try whereLine(addressOnly) == "192.0.2.11:2222")
    }
    @Test func storedDefaultPortDrawsNoExtra() throws {
        let (dir, store) = store(); defer { try? FileManager.default.removeItem(at: dir) }
        let row = try store.add(.init(name: "the box", address: "example.com", username: "ada")), s = BackendServersSummary(row)
        #expect(row.port == 22 && s.port == 22); #expect(try whereLine(s) == "ada at example.com")
        #expect(try whereLine(BackendServersSummary(.init(id: "address", name: "box", address: s.address, port: 22, username: ""))) == "example.com")
    }
    @Test func twoServersOnOneMachineHaveDifferentWhereLines() throws {
        let (dir, store) = store(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = BackendServersSummary(try store.add(.init(name: "a", address: "192.0.2.11", username: "admin"))), b = BackendServersSummary(try store.add(.init(name: "b", address: "192.0.2.11", port: 2222, username: "admin")))
        #expect(try whereLine(a) != whereLine(b))
    }
    @Test func exactDrawnFieldsComeFromReloadedRealList() throws {
        let (dir, store) = store(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try store.add(.init(name: "office pc", address: "192.0.2.11", port: 2222, username: "admin"))
        let reloaded = BackendServersStore(dataRoot: dir, policy: .init(mayRead: true, mayWrite: true)), row = try #require(reloaded.list().first), wire = BackendServersSummary(row).wireValue
        #expect(!row.id.isEmpty); #expect(wire == .object([.init("id", .string(row.id)), .init("name", .string("office pc")), .init("address", .string("192.0.2.11")), .init("port", .number(2222)), .init("username", .string("admin")), .init("credential", .string("none")), .init("drivesWindows", .bool(true))]))
    }
    @Test func newStoredServerLeavesClocksFolderAndUnseenIdentityBehind() throws {
        let (dir, store) = store(); defer { try? FileManager.default.removeItem(at: dir) }; let wire = BackendServersSummary(try store.add(.init(name: "office pc", address: "192.0.2.11", username: "admin"))).wireValue
        for field in ["addedAt", "lastConnectedAt", "startIn", "hostKey"] { #expect(!wire.has(field)) }
    }
    @Test func everyConsequenceFragmentIsWrittenInActionLayer() throws { let source = try String(contentsOf: sources.appendingPathComponent("TerminalDeckBackend/BackendServersActions.swift"), encoding: .utf8); for fragment in fragments { #expect(source.contains(fragment)) } }
    @Test func nativeRenderersNeverComposeConsequenceFragments() throws {
        // Same structural guard as the TypeScript renderer tree, applied to
        // native screen/core source. Read-only source inspection, no app startup.
        var offenders: [String] = []
        for folder in ["TerminalDeckNative", "TerminalDeckNativeCore"] {
            let root = sources.appendingPathComponent(folder)
            let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let file as URL in files where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                for fragment in fragments where source.contains(fragment) { offenders.append(file.lastPathComponent + " → " + fragment) }
            }
        }
        #expect(offenders == [])
    }
    @Test func everyActionHasNonemptyTargetNamedSentenceAndSamePreview() {
        let f = BackendServersProbe.parse("root=yes\ninit=systemd\ncontainers=docker\n#end ok", serverId: "s1", measuredAt: 1).actionFacts
        let cards: [BackendServersCard] = [.init(id: "repo", kind: .app, name: "td-scratch", managedBy: .systemd(unit: "td-scratch.service"), repoDir: "/opt/td-scratch"), .init(id: "container", kind: .app, name: "web", managedBy: .container(runtime: .docker, name: "web", compose: .init(project: "p", service: "web"))), .init(id: "site", kind: .site, name: "example.test", url: "https://example.test")]
        for id in BackendServersActionID.ordered { for card in cards { let target = BackendServersActionTarget(serverId: "s1", card: card, facts: f), sentence = BackendServersActions.summary(id, target: target); #expect(sentence.count > 4 && sentence.contains(card.name)); #expect(BackendServersActions.previewOf(id, target: target).sentence == sentence) } }
    }
    @Test func keptDatabasePreviewNamesCopyAndPlainContainerNamesKeptVersion() {
        let f = BackendServersProbe.parse("", serverId: "s", measuredAt: 1).actionFacts
        var card = BackendServersCard(id: "c", kind: .database, name: "db", managedBy: .container(runtime: .docker, name: "db", compose: .init(project: "p", service: "db")), engine: .postgres)
        let db = BackendServersActions.previewOf(.update, target: .init(serverId: "s", card: card, facts: f)); #expect(db.klass == .kept && db.keeps?.localizedCaseInsensitiveContains("copy of everything in this database") == true && db.sentence.localizedCaseInsensitiveContains("copy everything in it to your computer first"))
        card.engine = nil; let plain = BackendServersActions.previewOf(.update, target: .init(serverId: "s", card: card, facts: f)); #expect(plain.keeps?.localizedCaseInsensitiveContains("the version that is running now") == true); #expect(plain.wayBack == "Go back to the previous version")
    }
}
