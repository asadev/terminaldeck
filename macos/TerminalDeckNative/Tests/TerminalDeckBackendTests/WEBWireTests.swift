import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Web wire artifact previews and chat text", .serialized)
struct WEBWireTests {
    private typealias V = NativeRPCValue
    private actor Trace {
        var calls: [String] = []
        func add(_ name: String) { calls.append(name) }
    }
    private let rpc = NativeRPCContext(caller: .pairedDevice, ownerID: "fixture-browser", capabilities: ["filesystem.read"])
    private func parse(_ value: V) throws -> BackendRemoteClientMessage {
        guard case .message(let message) = BackendRemoteProtocol.parseClientMessage(value) else {
            throw NativeRPCError.malformed("Fixture frame was unexpectedly refused")
        }
        return message
    }
    private func isRefused(_ value: V) -> Bool {
        if case .refused = BackendRemoteProtocol.parseClientMessage(value) { return true }
        return false
    }
    private func snapshot(root: String, gone: Bool = false) -> V {
        typealias F = BackendRemoteServeMachinesTestsPanelsArtifactsFixtures
        return F.scanned([F.artifact("page.html", gone: gone)]).setting("root", .string(root))
    }
    private func seams(root: String, trace: Trace, gone: Bool = false, bytes: Bool = true) -> BackendRemotePanelArtifacts.Seams {
        let authority = BackendFilesystemAuthority(scope: { _ in .init(readRoots: [URL(fileURLWithPath: root)]) })
        let scan = snapshot(root: root, gone: gone)
        let read: @Sendable (String, String, Int, Int, NativeRPCContext) async throws -> V = { root, relative, at, maximum, context in
            await trace.add("bytes")
            return try await BackendWEBArtifactBytes.read(authority: authority, root: root, relative: relative, at: at, maximum: maximum, context: context)
        }
        return .init(list: { _, _, _ in await trace.add("list"); return scan },
            current: { _ in await trace.add("current"); return nil },
            serve: { _, _ in await trace.add("serve") }, link: { _, _, _ in await trace.add("link") },
            stop: { _ in await trace.add("stop") }, log: { _ in }, bytes: bytes ? read : nil)
    }

    @Test func realArtifactReadsAreBoundedChunksAndRequireCurrentFilesystemGrant() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WEBBytes-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let content = Data((0..<40_000).map { UInt8($0 % 251) })
        try content.write(to: directory.appendingPathComponent("page.html"))
        let authority = BackendFilesystemAuthority(scope: { _ in .init(readRoots: [directory]) })
        let first = try await BackendWEBArtifactBytes.read(authority: authority, root: directory.path, relative: "page.html", at: 0, maximum: 32_768, context: rpc)
        #expect(first["mime"].string == "text/html" && first["encoding"].string == "base64")
        #expect(first["offset"].number == 0 && first["next"].number == 32_768 && first["total"].number == 40_000)
        #expect(first["done"].bool == false)
        #expect(Data(base64Encoded: first["data"].string ?? "") == content.prefix(32_768))
        let last = try await BackendWEBArtifactBytes.read(authority: authority, root: directory.path, relative: "page.html", at: 32_768, maximum: 32_768, context: rpc)
        #expect(last["next"].number == 40_000 && last["done"].bool == true)
        #expect(Data(base64Encoded: last["data"].string ?? "") == content.suffix(7_232))
        for (at, maximum) in [(0, 32_769), (-1, 1), (40_001, 1), (0, 0)] {
            do { _ = try await BackendWEBArtifactBytes.read(authority: authority, root: directory.path, relative: "page.html", at: at, maximum: maximum, context: rpc); Issue.record("An invalid chunk was accepted") } catch {}
        }
        do {
            _ = try await BackendWEBArtifactBytes.read(authority: authority, root: directory.path, relative: "page.html", at: 0, maximum: 1,
                context: .init(caller: .pairedDevice, ownerID: "fixture-browser"))
            Issue.record("Artifact bytes were exposed without filesystem.read")
        } catch {}
        let denied = BackendFilesystemAuthority(scope: { _ in .init(readRoots: []) })
        do { _ = try await BackendWEBArtifactBytes.read(authority: denied, root: directory.path, relative: "page.html", at: 0, maximum: 1, context: rpc); Issue.record("A removed folder grant was ignored") } catch {}
        do { _ = try await BackendWEBArtifactBytes.read(authority: authority, root: directory.path, relative: "../escape.html", at: 0, maximum: 1, context: rpc); Issue.record("A relative path escaped its project") } catch {}
    }

    @Test func indexedPreviewReadsBytesAfterMembershipCheckAndNeverStartsAService() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WEBIndex-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("<h1>Fixture</h1>".utf8).write(to: directory.appendingPathComponent("page.html"))
        let trace = Trace(), provider = BackendRemotePanelArtifacts.provider(seams(root: directory.path, trace: trace))
        let result = try await provider.read(.init(path: directory.path, scope: nil, query: nil, preview: "page.html", offset: 0, maximum: 8), rpc)
        #expect(result["rows"].elements?.isEmpty == true)
        #expect(result["preview"]["token"].string == "page.html" && result["preview"]["kind"].string == "page")
        #expect(Data(base64Encoded: result["preview"]["data"].string ?? "")?.count == 8)
        let calls = await trace.calls
        #expect(calls == ["list", "current", "bytes"])
        do { _ = try await provider.read(.init(path: directory.path, scope: nil, query: nil, preview: "not-indexed.html"), rpc); Issue.record("An unlisted file reached the byte reader") } catch {}
        #expect(await trace.calls.filter { $0 == "bytes" }.count == 1)
        #expect(await trace.calls.allSatisfy { !["serve", "link", "stop"].contains($0) })
    }

    @Test func unavailableAndGonePreviewsFailBeforeByteAccessOrServing() async throws {
        for (gone, bytes) in [(false, false), (true, true)] {
            let trace = Trace(), provider = BackendRemotePanelArtifacts.provider(seams(root: "/fixture", trace: trace, gone: gone, bytes: bytes))
            do { _ = try await provider.read(.init(path: "/fixture", scope: nil, query: nil, preview: "page.html"), rpc); Issue.record("An unavailable preview succeeded") } catch {}
            #expect(await trace.calls == ["list", "current"])
        }
    }

    @Test func previewAndCorrelationParserRejectsUnusableOrOversizedFields() throws {
        let base = V.object([.init("t", .string("panel.read")), .init("panel", .string("artifacts")), .init("rid", .string("preview-1")), .init("path", .string("/fixture"))])
        let list = try parse(base)
        #expect(list["preview"] == .missing)
        let create = try parse(.object([.init("t", .string("create")), .init("rid", .string("create-terminal")),
            .init("cwd", .string("/fixture")), .init("provider", .string("shell")), .init("cols", .number(100)), .init("rows", .number(30))]))
        #expect(create["rid"].string == "create-terminal")
        let preview = base.setting("preview", .string("page.html")).setting("at", .number(2)).setting("max", .number(32_768))
        let parsed = try parse(preview)
        #expect(parsed["rid"].string == "preview-1" && parsed["preview"].string == "page.html")
        #expect(parsed["at"].number == 2 && parsed["max"].number == 32_768)
        for field in [V.null, .string(""), .string(String(repeating: "p", count: 129)), .string("bad\nname")] { #expect(isRefused(base.setting("preview", field))) }
        for field in [V.number(32_769), .number(0), .number(1.5)] { #expect(isRefused(preview.setting("max", field))) }
        for field in [V.number(-1), .number(1.5), .number(1_073_741_825)] { #expect(isRefused(preview.setting("at", field))) }
        #expect(try parse(base.setting("cursor", .number(200)))["cursor"].number == 200)
        for field in [V.number(-1), .number(201), .number(1.5)] { #expect(isRefused(base.setting("cursor", field))) }
        #expect(isRefused(preview.setting("panel", .string("tasks"))))
        #expect(isRefused(preview.setting("rid", .string(String(repeating: "r", count: 129)))))
    }

    @Test func panelRegistryCarriesPreviewBoundsAndEchoesRidForReadAndAction() async throws {
        let registry = BackendRemotePanelRegistry()
        try await registry.register(.artifacts, provider: .init(read: { request, _ in
            #expect(request.preview == "page.html" && request.offset == 16 && request.maximum == 64)
            return .object([.init("path", .string(request.path)), .init("rows", .array([]))])
        }))
        try await registry.register(.tasks, provider: .init(read: { request, _ in
            .object([.init("path", .string(request.path)), .init("rows", .array([])), .init("actions", .array([.object([.init("id", .string("add"))])]))])
        }, act: { request, _ in .object([.init("path", .string(request.panel.path)), .init("rows", .array([]))]) }))
        let context = BackendRemoteHostContext(connectionID: UUID(), deviceID: "fixture-browser", kind: .mine, address: "fixture", peerPublicKey: nil,
            claimedCapabilities: ["panels"], reach: .init(kind: .mine, unrestricted: true, folders: ["/fixture"], accounts: nil, drivesWindows: false), phoneAccess: .full)
        let read = try parse(.object([.init("t", .string("panel.read")), .init("panel", .string("artifacts")), .init("path", .string("/fixture")),
            .init("rid", .string("read-preview")), .init("preview", .string("page.html")), .init("at", .number(16)), .init("max", .number(64))]))
        let readReply = try await registry.handle(read, context: context)
        #expect(readReply.kind == .panelRows && readReply.value["rid"].string == "read-preview")
        let action = try parse(.object([.init("t", .string("panel.act")), .init("panel", .string("tasks")), .init("path", .string("/fixture")), .init("rid", .string("act-task")), .init("action", .string("add"))]))
        #expect(try await registry.handle(action, context: context).value["rid"].string == "act-task")
    }

    @Test func largeActionRowsPageBelowWireLimitWithoutLosingAnyOfTwoHundredIDs() throws {
        let rows: [V] = (0..<200).map { index in
            let field = V.object([.init("id", .string("details")), .init("type", .string("text")),
                .init("value", .string(String(repeating: "d", count: 2_000)))])
            let action = V.object([.init("id", .string("edit")), .init("fields", .array([field]))])
            return .object([.init("id", .string("task-\(index)")), .init("title", .string("Task \(index)")), .init("actions", .array([action]))])
        }
        let payload = V.object([.init("path", .string("/fixture")), .init("rows", .array(rows)), .init("note", .string("Fixture board"))])
        var cursor = 0, pages = 0, found: [String] = []
        while true {
            let page = try BackendWEBPanelPages.page(payload, cursor: cursor)
            #expect(page["cursor"].number == Double(cursor) && page["totalRows"].number == 200)
            let chunk = try #require(page["rows"].elements)
            #expect(!chunk.isEmpty)
            found.append(contentsOf: chunk.compactMap { $0["id"].string })
            let wire = try BackendRemoteServerMessage(.panelRows, fields: [.init("panel", .string("tasks")), .init("rid", .string("fixture-page"))] + (page.fields ?? []))
            #expect(try BackendRemoteProtocol.serializedBytes(wire).count < 65_536)
            pages += 1
            if page["nextCursor"] == .null { break }
            let next = Int(try #require(page["nextCursor"].number))
            #expect(next == cursor + chunk.count && next > cursor)
            cursor = next
            guard pages <= 200 else { Issue.record("Paging did not advance"); break }
        }
        #expect(pages > 1)
        #expect(found == (0..<200).map { "task-\($0)" })
        #expect(Set(found).count == 200)
    }

    @Test func invalidPageCursorsAndOneOversizedRowAreRefusedWithoutPartialSuccess() throws {
        let row = V.object([.init("id", .string("task-1")), .init("title", .string("Fixture"))])
        let base = V.object([.init("path", .string("/fixture")), .init("rows", .array([row]))])
        for cursor in [-1, 2, 201] {
            do { _ = try BackendWEBPanelPages.page(base, cursor: cursor); Issue.record("An invalid page cursor succeeded") }
            catch let error as NativeRPCError { #expect(error.code == "panel-changed") }
        }
        let end = try BackendWEBPanelPages.page(base, cursor: 1)
        #expect(end["rows"].elements?.isEmpty == true && end["nextCursor"] == .null)
        let huge = row.setting("title", .string(String(repeating: "x", count: 48_001)))
        do { _ = try BackendWEBPanelPages.page(base.setting("rows", .array([huge])), cursor: 0); Issue.record("An oversized single row succeeded") }
        catch let error as NativeRPCError { #expect(error.code == "panel-too-large") }
        do { _ = try BackendWEBPanelPages.page(base.setting("note", .string(String(repeating: "x", count: 48_001))), cursor: 0); Issue.record("Oversized page metadata succeeded") }
        catch let error as NativeRPCError { #expect(error.code == "panel-too-large") }
    }

    @Test func multilineChatTextPreservesWhitespaceButRejectsControlsAndByteOrFileOverflow() throws {
        for type in ["hoot.say", "chats.say", "chats.steer"] {
            let base = V.object([.init("t", .string(type)), .init("id", .string("chat-fixture")), .init("text", .string("First\nSecond\r\n\tLast"))])
            #expect(try parse(base)["text"].string == "First\nSecond\r\n\tLast")
            #expect(!isRefused(base.setting("text", .string(String(repeating: "x", count: 16_384)))))
            #expect(isRefused(base.setting("text", .string(String(repeating: "x", count: 16_385)))))
            #expect(!isRefused(base.setting("text", .string(String(repeating: "🙂", count: 4_096)))))
            #expect(isRefused(base.setting("text", .string(String(repeating: "🙂", count: 4_097)))))
            for control in ["\u{0}", "\u{1b}", "\u{7f}", "\u{85}"] { #expect(isRefused(base.setting("text", .string("a" + control + "b")))) }
            let files = (0..<4).map { V.string("/fixture/uploads/\($0).png") }
            #expect(!isRefused(base.setting("text", .string("")).setting("files", .array(files))))
            #expect(isRefused(base.setting("files", .array(files + [.string("/fixture/uploads/extra.png")]))))
            #expect(isRefused(base.setting("files", .array([.string("relative.png")]))))
        }
    }
}
