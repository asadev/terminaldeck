import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Open files with every Mac off (15 Nov; design `macos/night/codex/cloud-open-files-design.md`, contract C): Cloud
/// folder and artifact FILE rows carry hash, size and type; an unchanged file is never hashed twice; only the files the
/// service asks for are sent, in 1 MiB pieces, resumed after an interruption; the service live before this (no
/// `limits.fileKinds`, no `needFiles`, no files route) gets nothing new; over 25 MB, a link or a secret file never goes;
/// the switch off sends nothing. Scratch folders only.
@Suite("Cloud shelf: files his phones can open when the Macs are off")
struct CloudShelfFilesTests {
    typealias Shelf = BackendCloudShelf

    /// The service of contract C, kept small. `keepsFiles` false = the service live before this: no `limits.fileKinds`,
    /// rows with file fields refused (400, as its row check does), no `needFiles`, no files route (404).
    final class FakeService: @unchecked Sendable {
        let lock = NSLock()
        var keepsFiles = true
        /// The list knows files but the files route itself is gone (the service's kill switch): 404.
        var filesRouteMissing = false
        var lists: [String: [[String: Any]]] = [:]
        var pieces: [String: [Int: Data]] = [:]
        var calls: [(method: String, path: String, body: [String: Any])] = []
        /// After this many stored pieces, the connection drops (nil = never).
        var dropAfter: Int?
        var stored = 0
        func json(_ value: Any) -> Data { (try? JSONSerialization.data(withJSONObject: value)) ?? Data() }
        func refuse(_ status: Int, _ code: String) -> (status: Int, data: Data) { (status, json(["error": ["code": code, "message": code]])) }
        func paths() -> [String] { lock.withLock { calls.map { $0.method + " " + $0.path } } }
        func fileCalls() -> [[String: Any]] { lock.withLock { calls.filter { $0.path == "/shelf/files" }.map(\.body) } }
        func clear() { lock.withLock { calls = [] } }
        func needFiles(_ kind: String) -> [[String: Any]] {
            var seen: Set<String> = []
            return (lists[kind] ?? []).compactMap { row in
                guard let hash = row["fileHash"] as? String, let bytes = row["fileBytes"] as? Int, seen.insert(hash).inserted else { return nil }
                let missing = (0..<Shelf.filePieces(Int64(bytes))).filter { pieces[hash]?[$0] == nil }
                return missing.isEmpty ? nil : ["hash": hash, "pieces": missing]
            }
        }
        func whole(_ hash: String) -> Data? {
            guard let held = pieces[hash] else { return nil }
            return held.keys.sorted().reduce(into: Data()) { $0.append(held[$1]!) }
        }
        var send: BackendCloudShelfPutter.Send { { [self] method, path, body in try self.answer(method, path, body) } }
        func answer(_ method: String, _ path: String, _ body: Data) throws -> (status: Int, data: Data) {
            try lock.withLock {
                let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
                calls.append((method, path, object))
                if method == "GET", path.hasPrefix("/shelf") {
                    var made: [String: Any] = ["on": true, "kinds": [] as [Any]]
                    if keepsFiles { made["limits"] = ["fileKinds": ["memory", "instructionFiles", "cloudFolder", "artifacts"]] }
                    if let kind = path.components(separatedBy: "kind=").dropFirst().first {
                        made["needTexts"] = [] as [Any]
                        if keepsFiles { made["needFiles"] = needFiles(kind) }
                    }
                    return (200, json(made))
                }
                if path == "/shelf/setting" { return (200, json(["on": object["on"] as? Bool ?? true])) }
                if path == "/shelf/list" {
                    let kind = object["kind"] as! String
                    let rows = object["items"] as? [[String: Any]] ?? []
                    if !keepsFiles, rows.contains(where: { $0["fileHash"] != nil || $0["fileBytes"] != nil || $0["fileType"] != nil }) {
                        return refuse(400, "bad_request")
                    }
                    lists[kind] = rows
                    var made: [String: Any] = ["accepted": true, "asOf": 2_000, "count": rows.count, "dropped": 0, "needTexts": [] as [Any]]
                    if keepsFiles { made["needFiles"] = needFiles(kind); made["noRoom"] = 0 }
                    return (200, json(made))
                }
                if path == "/shelf/files" {
                    guard keepsFiles, !filesRouteMissing else { return refuse(404, "not_found") }
                    if let dropAfter, stored >= dropAfter { throw URLError(.networkConnectionLost) }
                    let kind = object["kind"] as! String, hash = object["hash"] as! String, piece = object["piece"] as! Int
                    guard let row = (lists[kind] ?? []).first(where: { $0["fileHash"] as? String == hash }), let bytes = row["fileBytes"] as? Int else {
                        return (200, json(["stored": false, "code": "not_on_shelf"]))
                    }
                    let data = Data(base64Encoded: object["data"] as! String) ?? Data()
                    guard piece < Shelf.filePieces(Int64(bytes)), data.count == min(Shelf.filePieceBytes, bytes - piece * Shelf.filePieceBytes) else {
                        return (200, json(["stored": false, "code": "bad_piece"]))
                    }
                    pieces[hash, default: [:]][piece] = data
                    stored += 1
                    return (200, json(["stored": true, "complete": pieces[hash]!.count == Shelf.filePieces(Int64(bytes))]))
                }
                return refuse(404, "not_found")
            }
        }
    }

    static func scratchRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-shelf-files-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    static func stateFile(_ root: URL) -> URL { root.appendingPathComponent("state/shelf.json") }
    static func bytes(_ count: Int, seed: UInt8 = 7) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) }) }
    static func ask(_ root: URL, _ relative: String, text: Bool = false) -> Shelf.FileAsk {
        .init(item: "cloudFolder||" + relative, kind: .cloudFolder, root: root, relative: relative, isText: text)
    }
    /// The rows Native's round makes: each asked item's row with its file fields.
    static func rows(_ asks: [Shelf.FileAsk], _ found: Shelf.FilesFound) -> [Shelf.Row] {
        asks.map { Shelf.withFile(Shelf.Row(key: $0.item, name: $0.relative, changedAt: 1, binary: !$0.isText), found.byItem[$0.item]?.fact) }
    }
    static func noText() -> @Sendable (String) async -> String? { { _ in nil } }
    static func reader(_ root: URL) -> @Sendable (BackendCloudContents.Kind, String) async -> Data? {
        { _, hash in
            for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
                if let data = Shelf.fileBytes(root: root, relative: name, hash: hash) { return data }
            }
            return nil
        }
    }
    /// A putter that already knows the service keeps files (the launch's `GET /v1/shelf`).
    static func livePutter(_ service: FakeService, _ file: URL) async -> BackendCloudShelfPutter {
        let putter = BackendCloudShelfPutter(send: service.send, file: file)
        _ = await putter.status()
        return putter
    }

    @Test("a picture, a PDF and a text over 1 MB carry hash, size and type; a small text does not")
    func rowsCarryHashSizeType() throws {
        let root = try Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = Self.bytes(3_000), pdf = Self.bytes(5_000, seed: 3), big = Data(repeating: 0x61, count: Shelf.textMaxBytes + 10)
        try png.write(to: root.appendingPathComponent("photo.png"))
        try pdf.write(to: root.appendingPathComponent("plan.pdf"))
        try big.write(to: root.appendingPathComponent("big.txt"))
        try Data("Notes.".utf8).write(to: root.appendingPathComponent("notes.md"))
        let asks = [Self.ask(root, "photo.png"), Self.ask(root, "plan.pdf"), Self.ask(root, "big.txt", text: true), Self.ask(root, "notes.md", text: true)]
        let found = Shelf.fileFacts(asks, known: [:])
        let rows = Dictionary(uniqueKeysWithValues: Self.rows(asks, found).map { ($0.name, $0) })
        #expect(rows["photo.png"]?.fileHash == Shelf.hash(png) && rows["photo.png"]?.fileBytes == 3_000 && rows["photo.png"]?.fileType == "image/png")
        #expect(rows["plan.pdf"]?.fileHash == Shelf.hash(pdf) && rows["plan.pdf"]?.fileType == "application/pdf")
        #expect(rows["big.txt"]?.fileHash == Shelf.hash(big) && rows["big.txt"]?.fileType == "text/plain")
        #expect(rows["notes.md"]?.fileHash == nil && rows["notes.md"]?.fileBytes == nil)
        #expect(Shelf.fileType("archive.unknownending") == "application/octet-stream")
        let encoded = String(decoding: (try? JSONEncoder().encode(rows["photo.png"]!)) ?? Data(), as: UTF8.self)
        #expect(encoded.contains("\"fileHash\"") && encoded.contains("\"fileBytes\":3000") && encoded.contains("\"fileType\":\"image\\/png\""))
    }

    @Test("an unchanged file is never read for its hash again; a changed one is")
    func unchangedNotHashedTwice() throws {
        let root = try Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.bytes(2_000).write(to: root.appendingPathComponent("a.png"))
        try Self.bytes(4_000).write(to: root.appendingPathComponent("b.jpg"))
        let asks = [Self.ask(root, "a.png"), Self.ask(root, "b.jpg")]
        let first = Shelf.fileFacts(asks, known: [:])
        #expect(first.read == 2 && first.keep.count == 2)
        let second = Shelf.fileFacts(asks, known: first.keep)
        #expect(second.read == 0)
        #expect(second.byItem["cloudFolder||a.png"]?.fact == first.byItem["cloudFolder||a.png"]?.fact)
        try Self.bytes(2_500, seed: 9).write(to: root.appendingPathComponent("a.png"))
        let third = Shelf.fileFacts(asks, known: second.keep)
        #expect(third.read == 1)
        #expect(third.byItem["cloudFolder||a.png"]?.fact.hash == Shelf.hash(Self.bytes(2_500, seed: 9)))
        // The first fill spreads: past the round's budget the rest waits (the first file always goes).
        let tight = Shelf.fileFacts(asks, known: [:], budget: 1)
        #expect(tight.read == 1 && tight.pending)
    }

    @Test("only the files the service asks for are sent, in 1 MiB pieces, and they arrive whole")
    func onlyAskedFilesInPieces() async throws {
        let root = try Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let big = Self.bytes(Shelf.filePieceBytes * 2 + 500_000), small = Self.bytes(700, seed: 5)
        try big.write(to: root.appendingPathComponent("film.mov"))
        try small.write(to: root.appendingPathComponent("icon.png"))
        let service = FakeService()
        service.pieces[Shelf.hash(small)] = [0: small]   // already on the shelf (another Mac sent it)
        let putter = await Self.livePutter(service, Self.stateFile(root))
        let asks = [Self.ask(root, "film.mov"), Self.ask(root, "icon.png")]
        let rows = Self.rows(asks, Shelf.fileFacts(asks, known: [:]))
        #expect(await putter.put(.cloudFolder, rows: rows, throughSeq: "1", from: nil, text: Self.noText()) == .put(count: 2, texts: 0))
        #expect(await putter.filesProgress()?.total == 1)
        let sent = await putter.sendFiles(maySend: { _ in true }, spent: { _ in }, bytes: Self.reader(root))
        let calls = service.fileCalls()
        #expect(sent == 3 && calls.count == 3)
        #expect(Set(calls.compactMap { $0["hash"] as? String }) == [Shelf.hash(big)])
        #expect(calls.compactMap { $0["piece"] as? Int } == [0, 1, 2])
        #expect(calls.compactMap { ($0["data"] as? String).flatMap { Data(base64Encoded: $0)?.count } } == [Shelf.filePieceBytes, Shelf.filePieceBytes, 500_000])
        #expect(service.whole(Shelf.hash(big)) == big)
        #expect(await putter.filesProgress() == nil)
        // Nothing more is owed: the next round sends nothing.
        service.clear()
        #expect(await putter.sendFiles(maySend: { _ in true }, spent: { _ in }, bytes: Self.reader(root)) == 0)
        #expect(service.fileCalls().isEmpty)
    }

    @Test("an interrupted file resumes after a restart where it stopped, asking the service what is still missing")
    func resumesAfterInterruption() async throws {
        let root = try Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let big = Self.bytes(Shelf.filePieceBytes * 2 + 10)
        try big.write(to: root.appendingPathComponent("scan.pdf"))
        let service = FakeService()
        service.dropAfter = 1
        let file = Self.stateFile(root)
        let first = await Self.livePutter(service, file)
        let asks = [Self.ask(root, "scan.pdf")]
        _ = await first.put(.cloudFolder, rows: Self.rows(asks, Shelf.fileFacts(asks, known: [:])), throughSeq: "1", from: nil, text: Self.noText())
        #expect(await first.sendFiles(maySend: { _ in true }, spent: { _ in }, bytes: Self.reader(root)) == 1)
        #expect(await first.state.kinds["cloudFolder"]?.filesOwed?.first?.pieces == [1, 2])
        // The app quits and starts again; the connection is back.
        service.dropAfter = nil
        service.clear()
        let again = await Self.livePutter(service, file)
        #expect(await again.filesProgress().map { [$0.done, $0.total] } == [0, 1])
        #expect(await again.sendFiles(maySend: { _ in true }, spent: { _ in }, bytes: Self.reader(root)) == 2)
        #expect(service.paths().contains("GET /shelf?kind=cloudFolder"))
        #expect(service.fileCalls().compactMap { $0["piece"] as? Int } == [1, 2])
        #expect(service.whole(Shelf.hash(big)) == big)
    }

    @Test("the daily allowance stops the files; they go on when it allows again")
    func dailyAllowance() async throws {
        let root = try Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.bytes(Shelf.filePieceBytes + 1).write(to: root.appendingPathComponent("a.png"))
        let service = FakeService()
        let putter = await Self.livePutter(service, Self.stateFile(root))
        let asks = [Self.ask(root, "a.png")]
        _ = await putter.put(.cloudFolder, rows: Self.rows(asks, Shelf.fileFacts(asks, known: [:])), throughSeq: "1", from: nil, text: Self.noText())
        let budget = CloudDayBudget(file: root.appendingPathComponent("state/file-day-budget.json"))
        let share = Int64(Shelf.filePieceBytes)
        let day = Int64(Date().timeIntervalSince1970 * 1000) / Shelf.dayMs
        let may: @Sendable (Int64) -> Bool = { budget.sent(day: day) + $0 <= share }
        let spent: @Sendable (Int64) -> Void = { budget.add($0, day: day) }
        #expect(await putter.sendFiles(maySend: may, spent: spent, bytes: Self.reader(root)) == 1)
        #expect(budget.sent(day: day) == Int64(Shelf.filePieceBytes))
        #expect(await putter.sendFiles(maySend: may, spent: spent, bytes: Self.reader(root)) == 0)
        #expect(await putter.sendFiles(maySend: { _ in true }, spent: spent, bytes: Self.reader(root)) == 1)
    }

    @Test("the service live today: rows exactly as before, nothing hashed into them, nothing sent, no error, no loop")
    func oldServiceSendsNothing() async throws {
        let root = try Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.bytes(5_000).write(to: root.appendingPathComponent("photo.png"))
        let service = FakeService()
        service.keepsFiles = false
        let putter = await Self.livePutter(service, Self.stateFile(root))
        #expect(await putter.filesLive(.cloudFolder) == false)
        // Native fills file fields only while the kind is live: the row is the plain row of before, and it is accepted.
        let plain = Shelf.Row(key: "cloudFolder||photo.png", name: "photo.png", changedAt: 1, binary: true)
        #expect(await putter.put(.cloudFolder, rows: [plain], throughSeq: "1", from: nil, text: Self.noText()) == .put(count: 1, texts: 0))
        let item = (service.calls.last { $0.path == "/shelf/list" }?.body["items"] as? [[String: Any]])?.first ?? [:]
        #expect(Set(item.keys) == ["key", "name", "changedAt", "binary"])
        #expect(await putter.sendFiles(maySend: { _ in true }, spent: { _ in }, bytes: Self.reader(root)) == 0)
        #expect(service.fileCalls().isEmpty)
        #expect(await putter.filesProgress() == nil)

        // A live claim but the route answers 404 (switched off on the service): nothing more until the next daily put;
        // the shelf's own puts keep working (no "service missing").
        let other = FakeService()
        let live = await Self.livePutter(other, root.appendingPathComponent("other/shelf.json"))
        let asks = [Self.ask(root, "photo.png")]
        _ = await live.put(.cloudFolder, rows: Self.rows(asks, Shelf.fileFacts(asks, known: [:])), throughSeq: "1", from: nil, text: Self.noText())
        other.filesRouteMissing = true
        #expect(await live.sendFiles(maySend: { _ in true }, spent: { _ in }, bytes: Self.reader(root)) == 0)
        #expect(other.fileCalls().count == 1)
        #expect(await live.missing == false)
        #expect(await live.filesLive(.cloudFolder) == false)
        #expect((await live.state.kinds["cloudFolder"]?.filesHoldUntil ?? 0) > Int64(Date().timeIntervalSince1970 * 1000))
        other.clear()
        #expect(await live.sendFiles(maySend: { _ in true }, spent: { _ in }, bytes: Self.reader(root)) == 0)
        #expect(other.paths().isEmpty)
        #expect(await live.put(.tasks, rows: [Shelf.Row(key: "tasks||A", name: "A task", changedAt: 1)], throughSeq: "2", from: nil, text: Self.noText()) == .put(count: 1, texts: 0))

        // A service whose answer names no files (`needFiles` absent): nothing is owed, nothing is sent.
        let quiet = FakeService()
        let third = await Self.livePutter(quiet, root.appendingPathComponent("third/shelf.json"))
        _ = await third.put(.cloudFolder, rows: Self.rows(asks, Shelf.fileFacts(asks, known: [:])), throughSeq: "1", from: nil, text: Self.noText())
        quiet.keepsFiles = false   // the next look (after a launch) has no `needFiles`
        let restarted = BackendCloudShelfPutter(send: quiet.send, file: root.appendingPathComponent("third/shelf.json"))
        #expect(await restarted.sendFiles(maySend: { _ in true }, spent: { _ in }, bytes: Self.reader(root)) == 0)
        #expect(quiet.fileCalls().isEmpty)
        #expect(await restarted.state.kinds["cloudFolder"]?.filesOwed == nil)
    }

    @Test("a file over 25 MB, a link and a file holding a secret are never hashed into a row nor sent")
    func neverSent() throws {
        let root = try Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let huge = root.appendingPathComponent("huge.mov")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(Shelf.fileMaxBytes) + 1)   // sparse: no real 25 MB written
        try handle.close()
        let real = Self.bytes(1_000)
        try real.write(to: root.appendingPathComponent("real.png"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.png"), withDestinationURL: root.appendingPathComponent("real.png"))
        let leaky = Data(("made-up config AKIA" + String(repeating: "Z", count: 16) + " end").utf8) + Data([0x00, 0x01])
        try leaky.write(to: root.appendingPathComponent("keys.bin"))
        let asks = [Self.ask(root, "huge.mov"), Self.ask(root, "link.png"), Self.ask(root, "keys.bin")]
        let found = Shelf.fileFacts(asks, known: [:])
        #expect(found.read == 1, "only the secret file is read; the huge one by its size alone, the link never")
        #expect(found.byItem["cloudFolder||link.png"] == nil)
        #expect(found.byItem["cloudFolder||huge.mov"]?.fact.hash == nil && found.byItem["cloudFolder||keys.bin"]?.fact.hash == nil)
        #expect(Self.rows(asks, found).allSatisfy { $0.fileHash == nil && $0.fileBytes == nil && $0.fileType == nil })
        #expect(Shelf.fileBytes(root: root, relative: "link.png", hash: Shelf.hash(real)) == nil)
        #expect(Shelf.fileBytes(root: root, relative: "keys.bin", hash: Shelf.hash(leaky)) == nil)
        #expect(Shelf.fileBytes(root: root, relative: "real.png", hash: Shelf.hash(real)) == real)
    }

    @Test("the switch off: nothing is owed, nothing is sent")
    func switchOffSendsNothing() async throws {
        let root = try Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.bytes(3_000).write(to: root.appendingPathComponent("a.png"))
        let service = FakeService()
        let putter = await Self.livePutter(service, Self.stateFile(root))
        let asks = [Self.ask(root, "a.png")]
        _ = await putter.put(.cloudFolder, rows: Self.rows(asks, Shelf.fileFacts(asks, known: [:])), throughSeq: "1", from: nil, text: Self.noText())
        await putter.setOn(false)
        service.clear()
        #expect(await putter.filesLive(.cloudFolder) == false)
        #expect(await putter.sendFiles(maySend: { _ in true }, spent: { _ in }, bytes: Self.reader(root)) == 0)
        #expect(service.fileCalls().isEmpty)
        #expect(await putter.filesProgress() == nil)
    }
}
