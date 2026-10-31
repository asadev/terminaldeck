import AppKit
import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

// SRVFILES #120: a local SSH-less fake server; no process, socket or real server.
private final class SRVFILESFake: BackendServersFilesTransport, @unchecked Sendable {
    let lock = NSLock()
    var files: [String: Data] = [:]
    var folders: Set<String> = ["/", "/home", "/home/deploy", "/etc", "/srv", "/srv/media"]
    var links: [String: String] = [:]
    var renamed: [(String, String)] = [], deleted: [String] = [], uploaded: [String] = []
    var scanRoots: [[String]] = [], scanSkips: [[String]] = []
    /// Extra "found so far" words a scan sends before its last one.
    var progressSteps = 0
    init() {}
    func add(_ path: String, _ text: String = "x", bytes: Data? = nil) {
        lock.withLock {
            files[path] = bytes ?? Data(text.utf8)
            var parent = BackendServersFilePaths.parent(path)
            while parent != "/" { folders.insert(parent); parent = BackendServersFilePaths.parent(parent) }
        }
    }
    func home(_ server: String) async throws -> String { "/home/deploy" }
    func realpath(_ server: String, _ path: String) async throws -> String {
        try lock.withLock {
            var p = BackendServersFilePaths.normalise(path)
            for (from, to) in links where p == from || p.hasPrefix(from + "/") { p = to + p.dropFirst(from.count) }
            guard folders.contains(p) || files[p] != nil else { throw BackendServersProblem("no-such-folder", "There is nothing at \(path) on this server.") }
            return p
        }
    }
    func list(_ server: String, _ path: String) async throws -> [BackendServersFileEntry] {
        lock.withLock {
            let prefix = path == "/" ? "/" : path + "/"
            var out: [BackendServersFileEntry] = []
            for f in folders where f != path && f.hasPrefix(prefix) && !f.dropFirst(prefix.count).contains("/") { out.append(.init(name: String(f.dropFirst(prefix.count)), path: f, kind: "folder", modified: 100)) }
            for (f, d) in files where f.hasPrefix(prefix) && !f.dropFirst(prefix.count).contains("/") { out.append(.init(name: String(f.dropFirst(prefix.count)), path: f, kind: "file", size: Int64(d.count), modified: Double(d.count))) }
            for (l, _) in links where l.hasPrefix(prefix) && !l.dropFirst(prefix.count).contains("/") { out.append(.init(name: String(l.dropFirst(prefix.count)), path: l, kind: "link")) }
            return out
        }
    }
    func stat(_ server: String, _ path: String) async throws -> BackendServersFileEntry {
        try lock.withLock {
            if let d = files[path] { return .init(name: (path as NSString).lastPathComponent, path: path, kind: "file", size: Int64(d.count), modified: 5) }
            if folders.contains(path) { return .init(name: (path as NSString).lastPathComponent, path: path, kind: "folder") }
            throw BackendServersProblem("no-such-folder", "There is nothing at \(path) on this server.")
        }
    }
    func read(_ server: String, _ path: String, from: Int, length: Int) async throws -> (bytes: Data, size: Int) {
        try lock.withLock {
            guard let d = files[path] else { throw BackendServersProblem("no-such-folder", "missing") }
            let s = min(from, d.count), e = min(d.count, s + length)
            return (Data(d[s..<e]), d.count)
        }
    }
    func download(_ server: String, _ path: String, to local: URL) async throws -> Int {
        let d = try lock.withLock { () throws -> Data in guard let d = files[path] else { throw BackendServersProblem("no-such-folder", "missing") }; return d }
        try d.write(to: local); return d.count
    }
    func rename(_ server: String, _ from: String, _ to: String) async throws { lock.withLock { renamed.append((from, to)); files[to] = files.removeValue(forKey: from) } }
    func delete(_ server: String, _ path: String, folder: Bool) async throws { lock.withLock { deleted.append(path); files[path] = nil } }
    func upload(_ server: String, local: URL, folder: String) async throws -> String { let p = folder + "/" + local.lastPathComponent; lock.withLock { uploaded.append(p) }; add(p); return p }
    func scan(_ server: String, roots: [String], skip: [String], extensions: [String], limit: Int, progress: @escaping @Sendable (Int, Int64) -> Void) async throws -> (entries: [BackendServersFileEntry], complete: Bool) {
        lock.withLock {
            scanRoots.append(roots); scanSkips.append(skip)
            let exts = Set(extensions)
            let rows = files.filter { f, _ in roots.contains { BackendServersFilePaths.inside(f, $0) } && exts.contains(BackendServersFileTypes.ext(f))
                && !BackendServersFilePaths.relative(f, roots: roots).contains { skip.contains($0) } }
                .map { BackendServersFileEntry(name: ($0.key as NSString).lastPathComponent, path: $0.key, kind: "file", size: Int64($0.value.count), modified: Double($0.value.count)) }
            for step in 0..<progressSteps { progress(step * rows.count / progressSteps, 0) }
            progress(rows.count, rows.reduce(0) { $0 + ($1.size ?? 0) })
            return (rows, true)
        }
    }
    func measure(_ server: String, _ path: String, type: String) async throws -> Double? { type == "audio" ? 187 : type == "document" ? 12 : nil }
    func serverThumbnail(_ server: String, _ path: String, type: String) async throws -> Data? { nil }
    func close(_ server: String) async {}
}

private actor SRVFILESChecks {
    var seen: [(String, BackendMCPTier)] = []
    func note(_ op: String, _ tier: BackendMCPTier) { seen.append((op, tier)) }
}

private actor SRVFILESEvents {
    var seen: [NativeRPCValue] = []
    func note(_ value: NativeRPCValue) { seen.append(value) }
}

private final class SRVFILESClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Double = 1_000
    var value: Double { get { lock.withLock { current } } set { lock.withLock { current = newValue } } }
}

private struct SRVFILESRig {
    let root: URL, store: BackendServersStore, fake = SRVFILESFake(), checks = SRVFILESChecks(), files: BackendServersFiles, server: String
    let ui = BackendServersCaller(kind: .nativeUI, attended: true, context: .init(caller: .nativeApp, ownerID: "srvfiles"))
    let ai = BackendServersCaller(kind: .key, attended: false, context: .init(caller: .internalEngine, ownerID: "srvfiles"), keyID: "k1")
    let shown = BackendServersShownApps()
    init(lookOnly: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("srvfiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = BackendServersStore(dataRoot: root, policy: .init(mayRead: true, mayWrite: true), serverAccessEnabled: false)
        server = try store.add(.init(name: "Demo box", address: "demo.example.invalid", username: "deploy")).id
        if lookOnly { _ = try store.setLookOnly(server, true) }
        let checks = self.checks
        files = BackendServersFiles(store: store, transport: fake, dataRoot: root, policy: .init(mayRead: true, mayWrite: true),
            downloads: root.appendingPathComponent("Downloads", isDirectory: true),
            check: { _, request in await checks.note(request.operation, request.tier) }, shownApps: shown)
        fake.add("/home/deploy/notes.txt", "hello server")
        fake.add("/home/deploy/.env", "SECRET=1")
        fake.add("/home/deploy/media/beach.jpg", String(repeating: "j", count: 300))
        fake.add("/home/deploy/media/clip.mp4", String(repeating: "v", count: 5000))
        fake.add("/home/deploy/media/song.mp3", String(repeating: "a", count: 40))
        fake.add("/home/deploy/docs/report.pdf", String(repeating: "p", count: 70))
        fake.add("/home/deploy/haji-crm/uploads/secret.jpg", "crm")
        fake.add("/home/deploy/iloop/logo.png", "iloop")
        fake.add("/etc/passwd", "root:x")
        fake.add("/srv/media/film.mov", "film")
        fake.links["/home/deploy/escape"] = "/etc"
    }
    func entries(_ value: NativeRPCValue) -> [String] { (value["entries"].elements ?? []).compactMap { $0["name"].string } }
}

@Suite("SRVFILES server files") struct SRVFILESTests {
    @Test func listsHomeByDefaultWithFoldersFirstAndPages() async throws {
        let rig = try SRVFILESRig()
        let page = try await rig.files.list(rig.server, path: "", caller: rig.ui)
        #expect(page["path"].string == "/home/deploy")
        #expect(page["parent"] == .null)
        #expect(Array(rig.entries(page).prefix(4)) == ["docs", "haji-crm", "iloop", "media"])
        let media = try await rig.files.list(rig.server, path: "media", sort: "size", descending: true, offset: 0, limit: 2, caller: rig.ui)
        #expect(rig.entries(media) == ["clip.mp4", "beach.jpg"])
        #expect(media["more"].bool == true && media["total"].number == 3 && media["parent"].string == "/home/deploy")
        let searched = try await rig.files.list(rig.server, path: "~/media", query: "SONG", caller: rig.ui)
        #expect(rig.entries(searched) == ["song.mp3"])
        #expect(page["entries"].elements?.first(where: { $0["name"].string == "notes.txt" })?["type"].string == "text")
    }

    @Test func refusesEverythingOutsideTheAllowedFolders() async throws {
        let rig = try SRVFILESRig()
        for path in ["/etc", "/home", "../../etc", "~/escape", "/home/deploy/escape/passwd"] {
            await #expect(throws: BackendServersFilesRefusal.self) { _ = try await rig.files.list(rig.server, path: path, caller: rig.ui) }
        }
        await #expect(throws: BackendServersFilesRefusal.self) { _ = try await rig.files.read(rig.server, path: "/etc/passwd", from: 0, length: 10, caller: rig.ui) }
        // The owner widens it: /srv/media opens, home no longer does.
        _ = try await rig.files.setFolders(rig.server, ["/srv/media"], caller: rig.ui)
        let srv = try await rig.files.list(rig.server, path: "", caller: rig.ui)
        #expect(srv["path"].string == "/srv/media" && rig.entries(srv) == ["film.mov"])
        await #expect(throws: BackendServersFilesRefusal.self) { _ = try await rig.files.list(rig.server, path: "/home/deploy", caller: rig.ui) }
        let again = BackendServersFolderLimits(dataRoot: rig.root, policy: .init(mayRead: true, mayWrite: true))
        #expect(again.folders(rig.server) == ["/srv/media"])
        await #expect(throws: BackendServersFilesRefusal.self) { _ = try await rig.files.setFolders(rig.server, ["/srv/media"], caller: rig.ai) }
        await #expect(throws: BackendServersFilesRefusal.self) { _ = try await rig.files.setFolders(rig.server, ["/nope"], caller: rig.ui) }
    }

    @Test func hidesFoldersOfHiddenApps() async throws {
        let rig = try SRVFILESRig()
        rig.shown.noteSeen(rig.server, names: ["haji-crm-app-1", "iloop-api", "iloop-worker"])
        rig.shown.set(rig.server, ["iloop-api"])
        let hidden = BackendServersFiles.hiddenFolders(rig.server, shown: rig.shown)
        #expect(hidden.contains("haji-crm") && !hidden.contains("iloop"))
        let page = try await rig.files.list(rig.server, path: "", caller: rig.ui)
        #expect(!rig.entries(page).contains("haji-crm") && rig.entries(page).contains("iloop"))
        await #expect(throws: BackendServersFilesRefusal.self) { _ = try await rig.files.list(rig.server, path: "haji-crm/uploads", caller: rig.ui) }
        let index = try await rig.files.scan(rig.server, caller: rig.ui)
        #expect(!index.entries.contains { $0.path.contains("haji-crm") })
        #expect(rig.fake.scanSkips.last?.contains("haji-crm") == true && rig.fake.scanSkips.last?.contains("node_modules") == true)
    }

    @Test func lookOnlyRefusesChangesBeforeAskingAndChangeServersAsk() async throws {
        let look = try SRVFILESRig(lookOnly: true)
        await #expect(throws: BackendServersFilesRefusal.self) { _ = try await look.files.rename(look.server, path: "notes.txt", to: "n.txt", caller: look.ui) }
        await #expect(throws: BackendServersFilesRefusal.self) { try await look.files.delete(look.server, path: "notes.txt", caller: look.ui) }
        let local = look.root.appendingPathComponent("up.txt"); try Data("up".utf8).write(to: local)
        await #expect(throws: BackendServersFilesRefusal.self) { _ = try await look.files.upload(look.server, local: local, folder: "", caller: look.ui) }
        #expect(await look.checks.seen.allSatisfy { $0.1 != .alter })
        #expect(look.fake.renamed.isEmpty && look.fake.deleted.isEmpty && look.fake.uploaded.isEmpty)
        // Look only still lists, previews and downloads.
        let saved = try await look.files.download(look.server, path: "notes.txt", caller: look.ui)
        #expect(try String(contentsOf: saved, encoding: .utf8) == "hello server" && saved.deletingLastPathComponent().lastPathComponent == "Downloads")
        let second = try await look.files.download(look.server, path: "notes.txt", caller: look.ui)
        #expect(second.lastPathComponent == "notes 2.txt")
        await #expect(throws: BackendServersFilesRefusal.self) { _ = try await look.files.download(look.server, path: "notes.txt", caller: look.ai) }

        let change = try SRVFILESRig()
        let target = try await change.files.rename(change.server, path: "notes.txt", to: "notes-old.txt", caller: change.ui)
        #expect(target == "/home/deploy/notes-old.txt")
        await #expect(throws: BackendServersFilesRefusal.self) { _ = try await change.files.rename(change.server, path: "notes-old.txt", to: "../x", caller: change.ui) }
        try await change.files.delete(change.server, path: "media/song.mp3", caller: change.ui)
        let up = change.root.appendingPathComponent("up.txt"); try Data("up".utf8).write(to: up)
        let placed = try await change.files.upload(change.server, local: up, folder: "docs", caller: change.ui)
        #expect(placed == "/home/deploy/docs/up.txt")
        let alters = await change.checks.seen.filter { $0.1 == .alter }.map(\.0)
        #expect(alters == ["servers:files:rename", "servers:files:delete", "servers:files:upload"])
        await #expect(throws: BackendServersFilesRefusal.self) { try await change.files.delete(change.server, path: "", caller: change.ui) }
    }

    @Test func mcpToolsKeepTheSameLimits() async throws {
        let rig = try SRVFILESRig(lookOnly: true)
        let listed = try await BackendServersFilesTools.invoke("servers.files_list", arguments: .object([.init("serverId", .string(rig.server))]), caller: rig.ai, files: rig.files)
        #expect(listed["path"].string == "/home/deploy")
        let read = try await BackendServersFilesTools.invoke("servers.files_read", arguments: .object([.init("serverId", .string(rig.server)), .init("path", .string("notes.txt"))]), caller: rig.ai, files: rig.files)
        #expect(read["text"].string == "hello server")
        await #expect(throws: BackendServersFilesRefusal.self) {
            _ = try await BackendServersFilesTools.invoke("servers.files_read", arguments: .object([.init("serverId", .string(rig.server)), .init("path", .string(".env"))]), caller: rig.ai, files: rig.files)
        }
        await #expect(throws: BackendServersFilesRefusal.self) {
            _ = try await BackendServersFilesTools.invoke("servers.files_read", arguments: .object([.init("serverId", .string(rig.server)), .init("path", .string("/etc/passwd"))]), caller: rig.ai, files: rig.files)
        }
        await #expect(throws: BackendServersFilesRefusal.self) {
            _ = try await BackendServersFilesTools.invoke("servers.files_change", arguments: .object([.init("serverId", .string(rig.server)), .init("do", .string("delete")), .init("path", .string("notes.txt"))]), caller: rig.ai, files: rig.files)
        }
        let device = BackendServersCaller(kind: .remote, attended: false, context: .init(caller: .pairedDevice, ownerID: "srvfiles"))
        await #expect(throws: BackendServersFilesRefusal.self) {
            _ = try await BackendServersFilesTools.invoke("servers.files_list", arguments: .object([.init("serverId", .string(rig.server))]), caller: device, files: rig.files)
        }
        let photos = try await BackendServersFilesTools.invoke("servers.gallery_list", arguments: .object([.init("serverId", .string(rig.server)), .init("type", .string("photo"))]), caller: rig.ai, files: rig.files)
        #expect(Set((photos["items"].elements ?? []).compactMap { $0["name"].string }) == ["beach.jpg", "logo.png", "secret.jpg"])
        #expect(try BackendServersFilesTools.definitions().map(\.wireName) == ["servers_files_list", "servers_files_read", "servers_gallery_list", "servers_files_change"])
        #expect(try BackendServersFilesTools.definitions().last?.tier == .alter)
        // A big read is cut to 256 KB for AI apps.
        rig.fake.add("/home/deploy/big.log", String(repeating: "z", count: 600_000))
        let big = try await BackendServersFilesTools.invoke("servers.files_read", arguments: .object([.init("serverId", .string(rig.server)), .init("path", .string("big.log")), .init("maxBytes", .number(900_000))]), caller: rig.ai, files: rig.files)
        #expect(big["bytesRead"].number == 262_144 && big["more"].bool == true)
    }

    @Test func mcpToolsClampHugeNumbersInsteadOfTrapping() async throws {
        let rig = try SRVFILESRig(lookOnly: true)
        let listed = try await BackendServersFilesTools.invoke("servers.files_list", arguments: .object([.init("serverId", .string(rig.server)), .init("offset", .number(1e300)), .init("limit", .number(1e300))]), caller: rig.ai, files: rig.files)
        #expect(listed["entries"].elements?.isEmpty == true && listed["offset"].number == listed["total"].number && listed["more"].bool == false)
        let read = try await BackendServersFilesTools.invoke("servers.files_read", arguments: .object([.init("serverId", .string(rig.server)), .init("path", .string("notes.txt")), .init("maxBytes", .number(1e19))]), caller: rig.ai, files: rig.files)
        #expect(read["text"].string == "hello server" && read["more"].bool == false)
        let past = try await BackendServersFilesTools.invoke("servers.files_read", arguments: .object([.init("serverId", .string(rig.server)), .init("path", .string("notes.txt")), .init("offset", .number(1e300)), .init("maxBytes", .number(-1e300))]), caller: rig.ai, files: rig.files)
        #expect(past["bytesRead"].number == 0 && past["offset"].number == 9_007_199_254_740_992 && past["more"].bool == false)
        let photos = try await BackendServersFilesTools.invoke("servers.gallery_list", arguments: .object([.init("serverId", .string(rig.server)), .init("type", .string("photo")), .init("offset", .number(1e300)), .init("limit", .number(-1e300))]), caller: rig.ai, files: rig.files)
        #expect(photos["items"].elements?.isEmpty == true && photos["offset"].number == 3)
    }

    @Test func galleriesGroupSortCountAndMeasure() async throws {
        let rig = try SRVFILESRig()
        let before = try await rig.files.gallery(rig.server, type: "photo", caller: rig.ui)
        #expect(before["scanned"].bool == false)
        _ = try await rig.files.scan(rig.server, caller: rig.ui)
        #expect(rig.fake.scanRoots.last == ["/home/deploy"])
        let videos = try await rig.files.gallery(rig.server, type: "video", caller: rig.ui)
        #expect((videos["items"].elements ?? []).compactMap { $0["name"].string } == ["clip.mp4"])
        #expect(videos["counts"]["photo"]["count"].number == 3 && videos["counts"]["audio"]["count"].number == 1 && videos["counts"]["document"]["count"].number == 1)
        let grouped = try await rig.files.gallery(rig.server, type: "photo", sort: "name", descending: false, group: "folder", caller: rig.ui)
        #expect((grouped["items"].elements ?? []).compactMap { $0["group"].string } == ["~/haji-crm/uploads", "~/iloop", "~/media"])
        let searched = try await rig.files.gallery(rig.server, type: "photo", query: "iloop", caller: rig.ui)
        #expect(searched["total"].number == 1)
        #expect(try await rig.files.measure(rig.server, path: "media/song.mp3", caller: rig.ui) == 187)
        let audio = try await rig.files.gallery(rig.server, type: "audio", caller: rig.ui)
        #expect(audio["items"].elements?.first?["seconds"].number == 187)
        // The index survives a restart; a removed server's cache is deleted.
        let again = BackendServersFiles(store: rig.store, transport: rig.fake, dataRoot: rig.root, policy: .init(mayRead: true, mayWrite: true), check: { _, _ in })
        #expect(try await again.gallery(rig.server, type: "document", caller: rig.ui)["total"].number == 1)
        _ = try rig.store.forget(rig.server)
        await again.sweepRemovedServers()
        #expect(!FileManager.default.fileExists(atPath: rig.root.appendingPathComponent("files-cache/\(rig.server)").path))
    }

    @Test func thumbnailsAndPreviewCopiesStayInTheirCaches() async throws {
        let rig = try SRVFILESRig()
        let image = NSImage(size: NSSize(width: 40, height: 30)); image.lockFocus(); NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 40, height: 30).fill(); image.unlockFocus()
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        rig.fake.add("/home/deploy/media/real.png", bytes: png)
        let thumb = try #require(try await rig.files.thumbnail(rig.server, path: "media/real.png", caller: rig.ui))
        #expect(thumb.path.contains("files-cache") && NSImage(contentsOf: thumb) != nil)
        #expect(try await rig.files.thumbnail(rig.server, path: "media/beach.jpg", caller: rig.ui) == nil)
        let copy = try await rig.files.fetchForPreview(rig.server, path: "docs/report.pdf", caller: rig.ui)
        #expect(FileManager.default.fileExists(atPath: copy.path) && copy.path.contains("files-cache/preview"))
        rig.files.releasePreview(copy.path)
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        rig.files.releasePreview("/etc/passwd")
        await #expect(throws: BackendServersFilesRefusal.self) { _ = try await rig.files.thumbnail(rig.server, path: "media/real.png", caller: rig.ai) }
    }

    @Test func channelsAnswerInPlainWords() async throws {
        let rig = try SRVFILESRig()
        let context = NativeRPCContext(caller: .nativeApp, ownerID: "srvfiles")
        let out = try await BackendServersFilesChannels.invoke("servers:files:list", [.string(rig.server), .object([.init("path", .string("/etc"))])], context: context, files: rig.files, caller: rig.ui)
        #expect(out["ok"].bool == false && out["code"].string == "outside" && (out["sentence"].string ?? "").contains("outside the folders"))
        let bytes = try await BackendServersFilesChannels.invoke("servers:files:read", [.string(rig.server), .object([.init("path", .string("notes.txt")), .init("from", .number(6)), .init("length", .number(100))])], context: context, files: rig.files, caller: rig.ui)
        #expect(bytes["bytes"] == .bytes(Data("server".utf8)) && bytes["size"].number == 12)
        // U29 (#39): the window's own channels clamp numbers like the AI tools do.
        let far = try await BackendServersFilesChannels.invoke("servers:files:read", [.string(rig.server), .object([.init("path", .string("notes.txt")), .init("from", .number(1e300)), .init("length", .number(100))])], context: context, files: rig.files, caller: rig.ui)
        #expect(far["bytes"] == .bytes(Data()))
        let paged = try await BackendServersFilesChannels.invoke("servers:files:list", [.string(rig.server), .object([.init("offset", .number(1e300)), .init("limit", .number(1e300))])], context: context, files: rig.files, caller: rig.ui)
        #expect(paged["entries"].elements?.isEmpty == true)
        let folders = try await BackendServersFilesChannels.invoke("servers:files:folders", [.string(rig.server)], context: context, files: rig.files, caller: rig.ui)
        #expect(folders["saved"] == .null && folders["roots"].elements == [.string("/home/deploy")])
    }

    @Test func liveScanScriptAndLinesAreSafe() {
        let script = BackendServersFilesLive.scanScript(skip: ["node_modules", "it's"], extensions: ["jpg"], limit: 10)
        #expect(script.contains("-name 'it'\\''s'") && script.contains("-iname '*.jpg'") && script.contains("head -n 10") && script.contains("\"$@\""))
        let entry = BackendServersFilesLive.parseScanLine("2048\t1700000000.5\t/home/deploy/a b\tc.jpg")
        #expect(entry?.path == "/home/deploy/a b\tc.jpg" && entry?.size == 2048 && entry?.type == "photo")
        #expect(BackendServersFilesLive.parseScanLine("junk") == nil && BackendServersFilesLive.parseScanLine("1\t2\trelative") == nil)
        #expect(BackendServersFileTypes.looksSecret("/home/u/.ssh/config") && BackendServersFileTypes.looksSecret("/srv/app/.env.production") && !BackendServersFileTypes.looksSecret("/srv/app/readme.md"))
    }

    /// #507: a folder lookup that failed is not remembered: an empty answer is asked again at once, one missing a folder after a while.
    @Test func aFailedFolderLookupIsAskedAgain() async throws {
        let rig = try SRVFILESRig(), clock = SRVFILESClock()
        let files = BackendServersFiles(store: rig.store, transport: rig.fake, dataRoot: rig.root, policy: .init(mayRead: true, mayWrite: true),
                                        check: { _, _ in }, now: { clock.value }, shownApps: rig.shown)
        _ = try await files.setFolders(rig.server, ["/srv/media"], caller: rig.ui)
        await files.closeServer(rig.server)
        _ = rig.fake.lock.withLock { rig.fake.folders.remove("/srv/media") }
        await #expect(throws: BackendServersFilesRefusal.self) { _ = try await files.list(rig.server, path: "", caller: rig.ui) }
        _ = rig.fake.lock.withLock { rig.fake.folders.insert("/srv/media") }
        #expect(try await files.list(rig.server, path: "", caller: rig.ui)["path"].string == "/srv/media")
        _ = try await files.setFolders(rig.server, ["/srv/media", "/home/deploy/media"], caller: rig.ui)
        await files.closeServer(rig.server)
        _ = rig.fake.lock.withLock { rig.fake.folders.remove("/home/deploy/media") }
        #expect(try await files.allowedRoots(rig.server) == ["/srv/media"])
        _ = rig.fake.lock.withLock { rig.fake.folders.insert("/home/deploy/media") }
        #expect(try await files.allowedRoots(rig.server) == ["/srv/media"])
        clock.value += BackendServersFiles.rootsRetry
        #expect(try await files.allowedRoots(rig.server) == ["/srv/media", "/home/deploy/media"])
    }

    /// #509: scan progress arrives in order, never going back, and all of it before the scan says it is finished.
    @Test func scanProgressArrivesInOrderAndBeforeTheEnd() async throws {
        let rig = try SRVFILESRig(), events = SRVFILESEvents()
        rig.fake.progressSteps = 40
        let files = BackendServersFiles(store: rig.store, transport: rig.fake, dataRoot: rig.root, policy: .init(mayRead: true, mayWrite: true),
                                        check: { _, _ in }, publish: { _, value in await events.note(value) }, shownApps: rig.shown)
        _ = try await files.scan(rig.server, caller: rig.ui)
        let seen = await events.seen
        #expect(seen.count >= 2 && seen.last?["done"].bool == true)
        #expect(seen.dropLast().allSatisfy { $0["done"].bool == false })
        let found = seen.dropLast().compactMap { $0["found"].number }
        #expect(found == found.sorted())
    }
}

/// One real, read-only proof on request: TD_SRVFILES_LIVE=<ssh alias> TD_SRVFILES_HELPER=<helper>.
/// Scratch store (never Asad's app data), Look only, list home, preview one small text file,
/// a read-only gallery search. Nothing is written to the server.
@Suite("SRVFILES live proof", .enabled(if: ProcessInfo.processInfo.environment["TD_SRVFILES_LIVE"] != nil)) struct SRVFILESLiveProof {
    @Test func readOnlyHomeListingPreviewAndGallery() async throws {
        let environment = ProcessInfo.processInfo.environment
        let alias = try #require(environment["TD_SRVFILES_LIVE"])
        try #require(alias != "imza-vps", "never browse imza-vps")
        let helper = URL(fileURLWithPath: try #require(environment["TD_SRVFILES_HELPER"]))
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("srvfiles-live-\(UUID().uuidString.prefix(8))")
        let scratch = URL(fileURLWithPath: "/private/tmp/srvf-" + UUID().uuidString.prefix(6), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: scratch) }
        let policy = BackendServersStoragePolicy(mayRead: true, mayWrite: true)
        let store = BackendServersStore(dataRoot: root, policy: policy)
        let cipher = BackendBrowserPasswordsCipher(available: { false }, decrypt: { String(decoding: $0, as: UTF8.self) }, encrypt: { text, _ in Data(text.utf8) })
        let ssh = BackendServersSSH(scratchRoot: scratch, policy: .init(mayConnect: true, helperExecutable: helper, helperDispatchInstalled: FileManager.default.isExecutableFile(atPath: helper.path)),
                                    sshHome: home, agentSocket: BackendServersSSH.personAgentSocket())
        let credentials = BackendServersCredentials(dataRoot: root, cipher: cipher, policy: policy, keyValidator: ssh.keyValidator())
        let connections = BackendServersConnections(store: store, credentials: credentials, dialer: ssh)
        let resolved = try await BackendDockerMCPServerSSHConfig().resolve(alias: alias, home: home)
        let row = try store.add(.init(name: alias, address: resolved.hostname, port: resolved.port, username: resolved.user), sshAlias: alias, lookOnly: true)
        let files = BackendServersFiles(store: store, transport: BackendServersFilesLive(connections: connections), dataRoot: root, policy: policy,
                                        downloads: root.appendingPathComponent("Downloads"), check: { _, _ in }, shownApps: BackendServersShownApps())
        let ui = BackendServersCaller(kind: .nativeUI, attended: true, context: .init(caller: .nativeApp, ownerID: "srvfiles-live"))
        var log: [String] = ["SRVFILES live proof \(Date()) alias=\(alias) (Look only, scratch store)"]
        let started = Date()
        let page = try await files.list(row.id, path: "", caller: ui)
        let entries = page["entries"].elements ?? []
        log.append("list home: \(page["path"].string ?? "?") · \(Int(page["total"].number ?? 0)) items in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        for entry in entries.prefix(12) { log.append("  \(entry["kind"].string ?? "") \(entry["name"].string ?? "") \(entry["size"].number.map { String(Int($0)) } ?? "-")") }
        #expect(page["path"].string?.hasPrefix("/") == true && !entries.isEmpty)
        let small = entries.first { ["text", "code"].contains($0["type"].string ?? "") && ($0["size"].number ?? .infinity) <= 65_536 && !BackendServersFileTypes.looksSecret($0["path"].string ?? "") }
        if let small, let path = small["path"].string {
            let read = try await files.read(row.id, path: path, from: 0, length: 4096, caller: ui)
            log.append("preview \(path): \(read.bytes.count) / \(read.size) bytes, first line: \(String(decoding: read.bytes, as: UTF8.self).split(separator: "\n").first.map { String($0.prefix(60)) } ?? "")")
            #expect(read.size > 0)
        } else { log.append("no small text file in home to preview") }
        do { _ = try await files.list(row.id, path: "/etc", caller: ui); Issue.record("outside was allowed") } catch { log.append("/etc refused: \(error.localizedDescription.prefix(60))…") }
        do { _ = try await files.rename(row.id, path: entries.first?["path"].string ?? "x", to: "never", caller: ui); Issue.record("look only allowed a rename") } catch { log.append("rename refused before anything was sent: \(error.localizedDescription.prefix(50))…") }
        let scanStart = Date()
        let index = try await files.scan(row.id, caller: ui)
        let counts = BackendServersFileTypes.galleries.map { type in "\(type) \(index.entries.filter { $0.type == type }.count)" }.joined(separator: ", ")
        log.append("gallery search (read-only find): \(index.entries.count) files (\(counts)) in \(String(format: "%.1f", Date().timeIntervalSince(scanStart))) s, complete=\(index.complete)")
        if alias == "terminaldeck-server" {
            // The demo box's home has no media; prove the find script on its read-only /usr/share.
            let live = BackendServersFilesLive(connections: connections)
            let exts = BackendServersFileTypes.galleries.flatMap { BackendServersFileTypes.extensions(for: $0) }.sorted()
            let shared = try await live.scan(row.id, roots: ["/usr/share"], skip: BackendServersFiles.skipAlways, extensions: exts, limit: 5000) { _, _ in }
            let sample = shared.entries.prefix(3).map { "\($0.path) \($0.size ?? 0)B" }.joined(separator: "; ")
            log.append("find script on /usr/share (demo box, read-only): \(shared.entries.count) files, complete=\(shared.complete); e.g. \(sample)")
            #expect(!shared.entries.isEmpty && shared.entries.allSatisfy { $0.path.hasPrefix("/usr/share/") && $0.modified != nil })
            await live.close(row.id)
        }
        await files.closeServer(row.id)
        await connections.closeAll()
        let out = URL(fileURLWithPath: "/Users/imatch/Projects/Personal/td-native-shell/macos/design-2026-10-10/built.noindex/SRVFILES-live-proof.log")
        try log.joined(separator: "\n").appending("\n").write(to: out, atomically: true, encoding: .utf8)
        print(log.joined(separator: "\n"))
    }
}

/// Startup refused to run when two areas registered the same MCP tool name (files_list existed
/// twice). Register every statically known catalogue into one real MCP server, the same
/// duplicate check the app runs at launch.
@Suite("SRVFILES tool catalogue") struct SRVFILESToolCatalogue {
    @Test func everyStaticToolNameIsUnique() async throws {
        let server = BackendNativeMCPServer()
        var specs: [BackendMCPTool] = try BackendDeckToolsCatalogue.entries().map(\.spec)
        specs += try BackendServersTools.definitions()
        specs += try BackendServersFilesTools.definitions()
        specs += try BackendDockerMCP.definitions()
        var seen: [String: String] = [:]
        for spec in specs {
            for name in Set([spec.id, spec.wireName]) {
                #expect(seen[name] == nil, "\(name) is registered by both \(seen[name] ?? "") and \(spec.id)")
                seen[name] = spec.id
            }
            do { try await server.registerTool(spec, ownerID: "catalogue-check") { _, _ in .value(.null) } }
            catch { Issue.record("Registering \(spec.id) (\(spec.wireName)) failed: \(error)") }
        }
        #expect(specs.count > 40)
        #expect(seen["servers_files_list"] == "servers.files_list" && seen["files_list"] != "servers.files_list")
    }
}
