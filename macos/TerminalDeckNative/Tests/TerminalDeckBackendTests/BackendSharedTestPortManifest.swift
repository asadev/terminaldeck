import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendSharedTestPortManifest: XCTestCase {
    private func fixture(_ patch: NativeRPCValue = .object([])) -> NativeRPCValue {
        .object([.init("terminaldeck", .number(1)), .init("publisher", .string("acme")), .init("id", .string("pr-review")), .init("kind", .string("skill")), .init("name", .string("Pull request review")), .init("summary", .string("Reads a diff and writes the review you would have written.")), .init("version", .string("1.0.0")), .init("licence", .string("MIT")), .init("category", .string("code")), .init("tags", .array([.string("review"), .string("git")])), .init("agents", .array([.string("claude"), .string("codex")])), .init("platforms", .array([.string("darwin"), .string("linux")])), .init("delivery", .string("repo")), .init("pricing", .object([.init("model", .string("free"))])), .init("links", .object([.init("repo", .string("https://github.com/acme/pr-review"))])), .init("needs", .array([])), .init("install", .object([.init("dir", .string("skills/pr-review"))]))]).merging(patch)
    }
    private func parse(_ key: String, _ value: NativeRPCValue) -> BackendSharedStoreManifest.Parse { BackendSharedStoreManifest.parse(fixture(.object([.init(key, value)])).compact, expectedPublisher: "acme", expectedID: "pr-review") }
    func testVocabulariesAgreeWithActualInstallerAndStore() {
        let m = BackendSharedStoreManifest.self
        XCTAssertEqual(m.mcpRuntimes, ["node", "python"]); XCTAssertFalse(m.mcpRuntimes.contains("docker"))
        XCTAssertEqual(m.costs + ["unknown"], StoreFront.costOrder)
        XCTAssertEqual(m.kinds.count, 7); XCTAssertEqual(m.kindNames["tool"], "Open-source tool")
        XCTAssertFalse(m.kindNames.values.joined().lowercased().contains("plug"))
        for kind in m.kinds {
            XCTAssertTrue(m.kindNames[kind]?.contains(where: { !$0.isWhitespace }) == true)
            XCTAssertTrue(m.kindOneLine[kind]?.hasSuffix(".") == true)
            XCTAssertNotNil(m.kindHasArtifact[kind]); XCTAssertTrue([1, 2, 3].contains(m.kindTierFloor[kind]!))
        }
        for agent in m.agents { XCTAssertEqual(m.hookEvents[agent], BackendSessionHookInstallation.events[agent]) }
        XCTAssertEqual(m.agents.sorted(), BackendSessionHookInstallation.events.keys.sorted())
        for runtime in m.mcpRuntimes { XCTAssertNotNil(BackendMcpClientCatalogue.runtimeBinary[runtime]); XCTAssertEqual(m.runtimeCommand[runtime], BackendMcpClientCatalogue.runtimeBinary[runtime]) }
        XCTAssertNotNil(BackendMcpClientCatalogue.runtimeBinary["docker"])
        XCTAssertEqual(m.categories, McpStoreCatalog.shelves.filter { $0.id != "your-own" }.map(\.id))
    }
    func testAllClosedVocabularyRefusalsAndExactParsedInstall() throws {
        let good = BackendSharedStoreManifest.parse(fixture().compact, expectedPublisher: "acme", expectedID: "pr-review")
        let value = try XCTUnwrap(good.value)
        XCTAssertEqual(value["id"].string, "pr-review")
        XCTAssertEqual(value["install"], .object([.init("kind", .string("skill")), .init("dir", .string("skills/pr-review"))]))
        for (key, raw, reason) in [
            ("licence", NativeRPCValue.string("Proprietary"), "licence must be one of"),
            ("category", .string("misc"), "category must be one of"), ("kind", .string("binary"), "kind must be one of"),
            ("agents", .array([.string("claude"), .string("copilot")]), "agents[1] must be one of"),
            ("needs", .array([.string("gpu")]), "needs[0] must be one of"),
            ("links", .object([.init("repo", .string("https://example.com/acme/pr-review"))]), "links.repo must be on one of"),
        ] { XCTAssertTrue(parse(key, raw).why?.contains(reason) == true) }
        let oversized = NativeRPCValue.object([.init("terminaldeck", .number(1)), .init("filler", .string(String(repeating: "x", count: BackendSharedStoreManifest.maxManifestBytes)))])
        XCTAssertTrue(BackendSharedStoreManifest.parse(oversized.compact, expectedPublisher: "acme", expectedID: "pr-review").why?.contains("bytes or fewer") == true)
    }
    func testHookSuccessAndInventedEventRefusal() {
        func hook(_ event: String) -> NativeRPCValue { .object([.init("script", .string("hooks/notify.mjs")), .init("events", .array([.string(event)])), .init("runtime", .string("node"))]) }
        let m = BackendSharedStoreManifest.self
        XCTAssertNotNil(m.readInstallBlock(kind: "hooks", value: hook("SessionStart"), agents: ["claude", "codex"]).value)
        XCTAssertTrue(m.readInstallBlock(kind: "hooks", value: hook("OnPayday"), agents: ["claude", "codex"]).why?.contains("has no hook called OnPayday") == true)
    }
    func testPaidUnknownOffsiteAndToolRules() {
        XCTAssertNotNil(parse("pricing", .object([.init("model", .string("paid")), .init("note", .string("$9 a month, no free tier."))])).value)
        XCTAssertTrue(parse("pricing", .object([.init("model", .string("unknown"))])).why?.contains("pricing.model must be one of") == true)
        let offsite = fixture(.object([.init("kind", .string("tool")), .init("delivery", .string("off-site")), .init("install", .null), .init("pricing", .object([.init("model", .string("paid")), .init("note", .string("$29 once."))]))]))
        XCTAssertTrue(BackendSharedStoreManifest.parse(offsite.compact, expectedPublisher: "acme", expectedID: "pr-review").why?.contains("must say where to get it") == true)
        XCTAssertEqual(parse("kind", .string("tool")).why, "a tool is a program you install yourself, so it cannot carry an install block")
    }
    func testMcpPathPackageRefusalAndPythonExactCommand() throws {
        func install(package: String, runtime: String = "node", token: String) -> NativeRPCValue { .object([.init("runtime", .string(runtime)), .init("package", .string(package)), .init("args", .array([])), .init("inputs", .array([])), .init("token", .string(token))]) }
        for package in ["https://example.com/x.tgz", "../../etc/passwd"] { XCTAssertTrue(BackendSharedStoreManifest.readInstallBlock(kind: "mcp", value: install(package: package, token: "x"), agents: ["claude"]).why?.contains("not a path or an address") == true) }
        let python = try XCTUnwrap(BackendSharedStoreManifest.readInstallBlock(kind: "mcp", value: install(package: "mcp-thing", runtime: "python", token: "mcp-thing"), agents: ["claude"]).value)
        XCTAssertEqual(BackendSharedStoreManifest.composeMcpCommand(python), "uvx mcp-thing")
    }
    func testEveryKindResultAndExactTierSentences() {
        let m = BackendSharedStoreManifest.self
        let skill = m.deriveTier(kind: "skill", files: [.init(path: "SKILL.md", bytes: 10, mode: 0o100644), .init(path: "docs/notes.md", bytes: 10, mode: 0o100644)])
        XCTAssertEqual(skill.tier, 1); XCTAssertEqual(skill.because, "every file in it is text")
        let scripted = m.deriveTier(kind: "skill", files: [.init(path: "SKILL.md", bytes: 10, mode: 0o100644), .init(path: "bin/run.sh", bytes: 10, mode: 0o100644)])
        XCTAssertEqual(scripted.tier, 2); XCTAssertEqual(scripted.because, "it ships bin/run.sh")
        XCTAssertEqual(m.deriveTier(kind: "mcp", files: []).tier, 3); XCTAssertEqual(m.deriveTier(kind: "hooks", files: []).tier, 3)
        XCTAssertEqual(m.tierWords[3], "Runs a program on this machine"); XCTAssertEqual(m.tierWords[2], "Ships scripts the agent may run"); XCTAssertEqual(m.tierWords[1], "Text only — nothing runs")
        let installs: [(String, NativeRPCValue)] = [
            ("skill", .object([.init("dir", .string("skills/pr-review"))])), ("instructions", .object([.init("file", .string("INSTRUCTIONS.md"))])),
            ("hooks", .object([.init("script", .string("hooks/notify.mjs")), .init("events", .array([.string("SessionStart")])), .init("runtime", .string("node"))])),
            ("mcp", .object([.init("runtime", .string("node")), .init("package", .string("@acme/mcp-thing")), .init("args", .array([])), .init("inputs", .array([])), .init("token", .string("@acme/mcp-thing"))])),
            ("extension", .object([.init("dir", .string("extension")), .init("reach", .array([.string("*.example.com")]))])), ("routine", .object([.init("file", .string("routines/nightly.md"))])), ("tool", .null),
        ]
        for (kind, install) in installs {
            let raw = fixture(.object([.init("kind", .string(kind)), .init("install", install), .init("agents", .array([.string("claude")]))]))
            XCTAssertEqual(m.parse(raw.compact, expectedPublisher: "acme", expectedID: "pr-review").value?["kind"].string, kind)
        }
    }
}
