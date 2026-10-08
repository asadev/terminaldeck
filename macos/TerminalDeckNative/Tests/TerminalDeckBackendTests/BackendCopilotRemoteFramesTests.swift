import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

private actor BackendCopilotRemoteTestFiles: BackendCopilotFilesProviding {
    var writes = 0
    func list() -> [NativeRPCValue] { [.object([.init("id", .string("yours")), .init("name", .string("instructions.md")), .init("purpose", .string("Your instructions")), .init("owner", .string("you")), .init("exists", .bool(true)), .init("size", .number(10)), .init("modifiedAt", .number(1)), .init("writable", .bool(true))])] }
    func read(_ target: BackendRemoteProtocol.CopilotFileTarget) -> BackendCopilotRemoteFileText { .init(text: "whole file", error: nil) }
    func write(_ target: BackendRemoteProtocol.CopilotFileTarget, text: String) -> BackendCopilotRemoteFileWrite { writes += 1; return .init(ok: false, error: "Refused by the desktop’s validation.") }
    func reset() -> BackendCopilotRemoteFileWrite { writes += 1; return .init(ok: true, error: nil) }
    func forget(_ name: String) -> BackendCopilotRemoteFileWrite { writes += 1; return .init(ok: true, error: nil) }
}
@Suite("No phone frame names a tool; hello and per-call access gate every verb")
struct BackendCopilotRemoteFramesTests: Sendable {
    private let allowed: [String: Set<String>] = [
        "copilot.hello": [], "copilot.bye": [], "copilot.answer": ["id", "approved"],
        "copilot.attach": [], "copilot.detach": [], "copilot.state": [], "copilot.sessions": [], "copilot.log": ["limit", "before"],
        "copilot.pending": [], "copilot.start": [], "copilot.say": ["text"], "copilot.cancel": [], "copilot.stop": [],
        "copilot.interactive": ["on"], "copilot.files": [], "copilot.file.read": ["id"], "copilot.file.write": ["id", "text"],
        "copilot.file.reset": ["id"], "copilot.memory.delete": ["name"],
    ]
    @Test func parserDropsSmuggledToolsAndEveryTagHasOneTierOrIsUntiered() throws {
        #expect(Set(BackendCopilotRemoteSurface.frameTier.keys).isDisjoint(with: BackendCopilotRemoteSurface.untiered))
        #expect(Set(BackendCopilotRemoteSurface.frameTier.keys).union(BackendCopilotRemoteSurface.untiered) == Set(allowed.keys))
        let catalogue = try BackendDeckCoreCatalogueLiterals.builtins()
        #expect(catalogue.count > 10)
        let tools = Set(catalogue.flatMap { [$0.tool.id, $0.tool.wireName] })
        for (tag, fields) in allowed {
            var raw = NativeRPCValue.object([.init("t", .string(tag)), .init("tool", .string("settings.write")), .init("args", .object([])), .init("run", .string("secret"))])
            for field in fields {
                let value: NativeRPCValue
                switch field {
                case "id": value = .string(tag.contains("file") ? "yours" : "question-1")
                case "name": value = .string("feedback_old.md")
                case "text": value = .string("which session is stuck?")
                case "limit": value = .number(50)
                case "before": value = .string("row-9")
                default: value = .bool(true)
                }
                raw = raw.setting(field, value)
            }
            guard case .message(let parsed) = BackendRemoteProtocol.parseClientMessage(raw) else { Issue.record("Rejected decided frame \(tag)"); continue }
            #expect(Set(parsed.value.fields!.map(\.key)) == fields.union(["t"]))
            for field in parsed.value.fields! { if let value = field.value.string { #expect(!tools.contains(value)) } }
        }
        for tag in ["copilot.connect", "copilot.tool", "copilot.run", "copilot.approve", "copilot.allow"] {
            #expect(BackendCopilotRemoteSurface.frameTier[tag] == nil)
            guard case .refused = BackendRemoteProtocol.parseClientMessage(.object([.init("t", .string(tag))])) else { Issue.record("Unexpected inbound tag \(tag)"); continue }
        }
    }
    @Test func memoryIDsAreNamesNeverPathsAndWireLimitsStayExact() {
        #expect(BackendRemoteProtocol.copilotFileTarget("memory:reference_servers.md") != nil)
        for bad in ["memory:../secret.md", "memory:a/b.md", "memory:a\\b.md", "memory:", "/Users/owner/CLAUDE.md"] {
            #expect(BackendRemoteProtocol.copilotFileTarget(bad) == nil)
        }
        #expect(BackendRemoteProtocol.isCopilotMemoryName("reference_servers.md"))
        for tag in ["copilot.file.write", "hoot.file.write"] {
            let oversized = NativeRPCValue.object([.init("t", .string(tag)), .init("id", .string("yours")), .init("text", .string(String(repeating: "x", count: 32769)))])
            guard case .refused(let error) = BackendRemoteProtocol.parseClientMessage(oversized) else { Issue.record("Oversized file write was parsed"); continue }
            #expect(error.code == "too-large")
            #expect(error.reason == "copilot.file.write larger than the file limit")
        }
    }
    @Test func eachSocketNeedsHelloGuestsFailAndRevocationLandsOnNextFrame() async throws {
        let rig = try await BackendCopilotRemoteTestFixture()
        let router = BackendCopilotRemoteFrames(runs: rig.runs, send: { _, _ in })
        let context = BackendCopilotRemoteTestContext("phone")
        let before = await router.handle(try BackendCopilotRemoteTestMessage("copilot.state"), context: context)
        #expect(before.first?.value["code"].string == "unauthorized")
        #expect(before.first?.value["message"].string?.contains("not connected") == true)
        let hello = await router.handle(try BackendCopilotRemoteTestMessage("copilot.hello"), context: context)
        #expect(hello.first?.value["link"]["open"].bool == true)
        let guest = await router.handle(try BackendCopilotRemoteTestMessage("copilot.hello"), context: BackendCopilotRemoteTestContext("guest", mine: false))
        #expect(guest.first?.value["message"].string == "Hoot is not shared with guest devices. Pair this device again as your own to use it.")
        #expect(await router.welcomeLink(deviceID: "guest") == nil)
        let another = await router.handle(try BackendCopilotRemoteTestMessage("copilot.state"), context: BackendCopilotRemoteTestContext("phone"))
        #expect(another.first?.kind == .error)
        rig.box.change { $0.mine.remove("phone") }
        let revoked = await router.handle(try BackendCopilotRemoteTestMessage("copilot.state"), context: context)
        #expect(revoked.first?.value["message"].string == "Hoot is not shared with guest devices.")
        await router.stop(); await rig.finish()
    }
    @Test func fileWritesRedrawAfterRefusalAndOnlyOwnInstructionsReset() async throws {
        let rig = try await BackendCopilotRemoteTestFixture(), files = BackendCopilotRemoteTestFiles()
        let router = BackendCopilotRemoteFrames(runs: rig.runs, files: files, send: { _, _ in })
        let context = BackendCopilotRemoteTestContext("phone")
        _ = await router.handle(try BackendCopilotRemoteTestMessage("copilot.hello"), context: context)
        let write = await router.handle(try BackendCopilotRemoteTestMessage("copilot.file.write", fields: [.init("id", .string("yours")), .init("text", .string("hello"))]), context: context)
        #expect(write.map(\.kind) == [.error, .copilotFileRows])
        #expect(write.first?.value["message"].string == "Refused by the desktop’s validation.")
        let invalidReset = await router.handle(try BackendCopilotRemoteTestMessage("copilot.file.reset", fields: [.init("id", .string("contract"))]), context: context)
        #expect(invalidReset.map(\.kind) == [.error, .copilotFileRows]); #expect(await files.writes == 1)
        let read = await router.handle(try BackendCopilotRemoteTestMessage("copilot.file.read", fields: [.init("id", .string("yours"))]), context: context)
        #expect(read.first?.kind == .copilotFileText); #expect(read.first?.value["text"].string == "whole file")
        #expect(await router.features().map(\.capability) == ["copilot", "copilot.files"])
        await router.stop(); await rig.finish()
    }
    @Test func absentFilesAreUnadvertisedAndGiveClearRefusal() async throws {
        let rig = try await BackendCopilotRemoteTestFixture()
        let router = BackendCopilotRemoteFrames(runs: rig.runs, send: { _, _ in }), context = BackendCopilotRemoteTestContext("phone")
        #expect(await router.features().map(\.capability) == ["copilot"])
        _ = await router.handle(try BackendCopilotRemoteTestMessage("copilot.hello"), context: context)
        let reply = await router.handle(try BackendCopilotRemoteTestMessage("copilot.files"), context: context)
        #expect(reply.first?.value["message"].string == "Hoot’s files cannot be reached on this machine.")
        await router.stop(); await rig.finish()
    }
}
