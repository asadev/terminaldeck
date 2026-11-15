import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Sessions and chats in the Cloud, step 1, the Mac's uploader (owner, 15 Nov: chats live in the Cloud, kept until he
/// deletes them, however big). Only what was added goes up; nothing while idle; a crash resumes from what the service
/// holds; a big history goes up in 4 MiB pieces, readable copy first; a service without the routes is silent.
/// A stand-in service plays the Servers note's "Contract for the Mac".
@Suite("Cloud chats: the Mac's sessions and their chats go up as they grow")
struct CloudChatsTests {
    /// The contract's service, kept small: one machine, its list, each stream's bytes, tail parts and pieces.
    final class FakeService: @unchecked Sendable {
        struct Held { var gen = 1; var bytes = Data(); var pieced = 0; var pieces: [Int] = []; var tail: [Int] = [] }
        let lock = NSLock()
        var calls: [(method: String, path: String, body: [String: Any])] = []
        var list: [[String: Any]] = []
        var streams: [String: Held] = [:] // "session|stream"
        var snaps: [String: Data] = [:]
        var binned: [String: String] = [:] // ref -> last action
        var lists: [[[String: Any]]] = []
        var routesMissing = false
        var loseNextTick = false
        func paths() -> [String] { lock.withLock { calls.map { $0.method + " " + $0.path } } }
        func held(_ session: String, _ stream: String) -> Held? { lock.withLock { streams[session + "|" + stream] } }
        func json(_ value: Any) -> Data { (try? JSONSerialization.data(withJSONObject: value)) ?? Data() }
        func refuse(_ status: Int, _ code: String) -> (status: Int, data: Data) { (status, json(["error": ["code": code, "message": code]])) }
        var send: BackendCloudChatsUploader.Send { { [self] method, path, body in try self.answer(method, path, body) } }

        func raw(_ part: [String: Any]) -> Data? {
            guard let gz = (part["gz"] as? String).flatMap({ Data(base64Encoded: $0) }), let bytes = BackendCloudChats.gunzip(gz),
                  bytes.count == part["rawLen"] as? Int, BackendCloudChats.hex(bytes) == part["sha256"] as? String else { return nil }
            return bytes
        }
        func answer(_ method: String, _ path: String, _ body: Data) throws -> (status: Int, data: Data) {
            try lock.withLock {
                let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
                calls.append((method, path, object))
                if routesMissing { return refuse(404, "not_found") }
                if method == "GET", path.hasPrefix("/chats/head") {
                    var sessions: [String: [String: Any]] = [:]
                    for (key, held) in streams {
                        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                        var streamsOf = sessions[parts[0]]?["streams"] as? [String: Any] ?? [:]
                        streamsOf[parts[1]] = ["gen": held.gen, "length": held.bytes.count, "pieced": held.pieced, "pieces": held.pieces.count, "tailParts": held.tail]
                        sessions[parts[0]] = ["session": parts[0], "ref": parts[0], "binned": false, "closed": false, "streams": streamsOf]
                    }
                    return (200, json(["sessions": Array(sessions.values)]))
                }
                if path == "/chats/tick" {
                    if loseNextTick { loseNextTick = false; throw URLError(.networkConnectionLost) }
                    if let rows = object["sessions"] as? [[String: Any]] { list = rows; lists.append(rows) }
                    var answers: [[String: Any]] = []
                    for part in object["parts"] as? [[String: Any]] ?? [] {
                        let session = part["session"] as! String, stream = part["stream"] as! String
                        let gen = part["gen"] as! Int, from = part["from"] as! Int
                        let key = session + "|" + stream
                        var held = streams[key] ?? Held(gen: gen)
                        if gen > held.gen { guard from == 0 else { answers.append(["session": session, "stream": stream, "ok": false, "gen": held.gen, "have": held.bytes.count, "code": "chat_offset"]); continue }; held = Held(gen: gen) }
                        guard gen == held.gen else { answers.append(["session": session, "stream": stream, "ok": false, "gen": held.gen, "have": held.bytes.count, "code": "old_gen"]); continue }
                        guard from == held.bytes.count else { answers.append(["session": session, "stream": stream, "ok": false, "gen": held.gen, "have": held.bytes.count, "code": "chat_offset"]); continue }
                        guard let bytes = raw(part) else { answers.append(["session": session, "stream": stream, "ok": false, "gen": held.gen, "have": held.bytes.count, "code": "bad_bytes"]); continue }
                        if stream == "read" { #expect(bytes.last == 0x0a) } // whole lines only
                        held.bytes.append(bytes); held.tail.append(bytes.count)
                        streams[key] = held
                        answers.append(["session": session, "stream": stream, "ok": true, "gen": held.gen, "have": held.bytes.count])
                    }
                    return (200, json(["tickId": object["tickId"] ?? "", "parts": answers]))
                }
                if path == "/chats/piece" {
                    let session = object["session"] as! String, stream = object["stream"] as! String
                    let key = session + "|" + stream
                    var held = streams[key] ?? Held(gen: object["gen"] as! Int)
                    let index = object["index"] as! Int, rawFrom = object["rawFrom"] as! Int, rawLen = object["rawLen"] as! Int
                    guard index == held.pieces.count, rawFrom == held.pieced, let bytes = raw(object) else {
                        return (409, json(["ok": false, "code": "piece_boundary", "gen": held.gen, "have": held.bytes.count, "pieced": held.pieced, "pieces": held.pieces.count]))
                    }
                    if held.tail.isEmpty {
                        guard rawFrom == held.bytes.count else { return refuse(409, "chat_offset") }
                        held.bytes.append(bytes)
                    } else {
                        // Must end where one of the tail parts ends; the covered parts are dropped.
                        var sum = 0, covered = 0
                        for part in held.tail { sum += part; covered += 1; if sum >= rawLen { break } }
                        guard sum == rawLen, Data(held.bytes[rawFrom..<(rawFrom + rawLen)]) == bytes else { return refuse(409, "piece_mismatch") }
                        held.tail.removeFirst(covered)
                    }
                    held.pieced += rawLen; held.pieces.append(rawLen)
                    streams[key] = held
                    return (200, json(["ok": true, "gen": held.gen, "index": index, "pieced": held.pieced, "have": held.bytes.count]))
                }
                if path == "/chats/bin" {
                    let ref = (object["ref"] as? String) ?? (object["session"] as? String) ?? ""
                    let action = object["action"] as? String ?? ""
                    if action != "bin", binned[ref] == nil { return refuse(404, "not_binned") }
                    binned[ref] = action == "restore" ? nil : action
                    return (200, json(["ref": ref, "binnedAt": 1, "removeAt": 2]))
                }
                if path == "/chats/snap" {
                    let session = object["session"] as! String
                    snaps[session] = raw(object)
                    return (200, json(["ok": true]))
                }
                return refuse(404, "not_found")
            }
        }
    }
    final class Clock: @unchecked Sendable {
        let lock = NSLock(); var value: Int64 = 1_700_000_000_000
        var now: @Sendable () -> Int64 { { [self] in lock.withLock { value } } }
        func advance(_ ms: Int64) { lock.withLock { value += ms } }
    }

    static func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-chats-tests-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func user(_ n: Int) -> String {
        #"{"type":"user","message":{"role":"user","content":"question \#(n)"},"uuid":"u-\#(n)","timestamp":"2026-11-15T01:00:00.000Z","sessionId":"c1","cwd":"/tmp/p"}"# + "\n"
    }
    static func assistant(_ n: Int) -> String {
        #"{"type":"assistant","message":{"id":"m-\#(n)","model":"claude-opus","content":[{"type":"text","text":"answer \#(n)"}]},"uuid":"a-\#(n)","timestamp":"2026-11-15T01:00:01.000Z","sessionId":"c1"}"# + "\n"
    }
    /// A tool result about 1 KB long: history bytes with nothing readable in them.
    static func toolTraffic(_ n: Int) -> String {
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t-\#(n)","content":""# + String(repeating: "x", count: 960) + #""}]},"uuid":"t-\#(n)"}"# + "\n"
    }
    static func listed(_ file: URL, id: String = "tab-1") -> BackendCloudChats.Listed {
        .init(row: .init(sessionId: id, name: "CRM", lastUsedAt: 1_700_000_000_000, project: .init(cloudRef: "crm", name: "CRM"), cwd: "/tmp/p",
                         ai: "claude", kind: "terminal", status: "idle", startedAt: 1_699_000_000_000, conversationId: "c1"),
              source: .init(raw: file, readable: .claude, provider: .claude))
    }
    static func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8))
    }

    @Test("Only what was added is sent, and the list once")
    func onlyWhatWasAdded() async throws {
        let service = FakeService(), dir = Self.folder(), history = dir.appendingPathComponent("c1.jsonl")
        try (Self.user(1) + Self.assistant(1)).write(to: history, atomically: true, encoding: .utf8)
        let uploader = BackendCloudChatsUploader(send: service.send, directory: dir.appendingPathComponent("state"))
        let first = await uploader.round([Self.listed(history)])
        #expect(first == .sent(parts: 2, list: true))
        #expect(service.list.count == 1 && service.list[0]["sessionId"] as? String == "tab-1" && service.list[0]["status"] as? String == "idle")
        let before = try Data(contentsOf: history)
        #expect(service.held("tab-1", "raw")?.bytes == before)
        try Self.append(Self.user(2), to: history)
        service.calls = []
        let second = await uploader.round([Self.listed(history)])
        #expect(second == .sent(parts: 2, list: false))
        let tick = try #require(service.calls.first { $0.path == "/chats/tick" })
        let raw = try #require((tick.body["parts"] as? [[String: Any]])?.first { $0["stream"] as? String == "raw" })
        #expect(raw["from"] as? Int == before.count)
        #expect(raw["rawLen"] as? Int == Self.user(2).utf8.count)
        #expect(tick.body["sessions"] == nil)
        #expect(service.held("tab-1", "raw")?.bytes == (try Data(contentsOf: history)))
        // The readable copy: three messages, numbered on.
        let lines = String(decoding: service.held("tab-1", "read")?.bytes ?? Data(), as: UTF8.self).split(separator: "\n")
        #expect(lines.count == 3)
        let last = try HootChatEvent(wire: try NativeRPCValue.parseJSON(Data(lines[2].utf8)))
        #expect(last.sequence == 3 && last.record.kind == .user && last.record.value["text"].string == "question 2")
    }

    @Test("Nothing is sent while nothing grew")
    func nothingWhenIdle() async throws {
        let service = FakeService(), dir = Self.folder(), history = dir.appendingPathComponent("c1.jsonl")
        try Self.user(1).write(to: history, atomically: true, encoding: .utf8)
        let uploader = BackendCloudChatsUploader(send: service.send, directory: dir.appendingPathComponent("state"))
        _ = await uploader.round([Self.listed(history)])
        let count = service.calls.count
        #expect(await uploader.round([Self.listed(history)]) == .idle)
        #expect(await uploader.round([Self.listed(history)]) == .idle)
        #expect(service.calls.count == count)
    }

    @Test("A crash after the service took a tick resumes from what it holds; a lost answer sends the same tick again")
    func resume() async throws {
        let service = FakeService(), dir = Self.folder(), history = dir.appendingPathComponent("c1.jsonl")
        let state = dir.appendingPathComponent("state")
        try Self.user(1).write(to: history, atomically: true, encoding: .utf8)
        let first = BackendCloudChatsUploader(send: service.send, directory: state)
        _ = await first.round([Self.listed(history)])
        let saved = try Data(contentsOf: state.appendingPathComponent("state.json"))
        try Self.append(Self.assistant(1), to: history)
        _ = await first.round([Self.listed(history)])
        // The Mac stopped before it kept the second answer: its record still says the first length.
        try saved.write(to: state.appendingPathComponent("state.json"))
        try Self.append(Self.user(2), to: history)
        service.calls = []
        let second = BackendCloudChatsUploader(send: service.send, directory: state)
        _ = await second.round([Self.listed(history)])
        let rawParts = service.calls.filter { $0.path == "/chats/tick" }.flatMap { ($0.body["parts"] as? [[String: Any]]) ?? [] }.filter { $0["stream"] as? String == "raw" }
        #expect(rawParts.map { $0["from"] as? Int } == [(Self.user(1) + Self.assistant(1)).utf8.count])
        #expect(service.held("tab-1", "raw")?.bytes == (try Data(contentsOf: history)))
        #expect(service.held("tab-1", "raw")?.gen == 1)

        // A tick whose answer is lost goes again with the same id and bytes.
        try Self.append(Self.assistant(2), to: history)
        service.loseNextTick = true
        #expect(await second.round([Self.listed(history)]) == .later)
        let lostId = service.calls.last?.body["tickId"] as? String
        _ = await second.round([Self.listed(history)])
        #expect(service.calls.last { $0.path == "/chats/tick" }?.body["tickId"] as? String == lostId)
        #expect(service.held("tab-1", "raw")?.bytes == (try Data(contentsOf: history)))
    }

    @Test("A big history goes up in 4 MiB pieces, readable copy first, never as one tick")
    func bigHistoryInPieces() async throws {
        let service = FakeService(), dir = Self.folder(), history = dir.appendingPathComponent("c1.jsonl")
        var text = Self.user(1) + Self.assistant(1)
        for n in 0..<9_800 { text += Self.toolTraffic(n) }
        text += Self.user(2) + Self.assistant(2)
        try text.write(to: history, atomically: true, encoding: .utf8)
        let size = try Data(contentsOf: history).count
        #expect(size > 9 * 1_048_576)
        let uploader = BackendCloudChatsUploader(send: service.send, directory: dir.appendingPathComponent("state"))
        // The live tick carries the list only: the history is far too big for it.
        #expect(await uploader.round([Self.listed(history)]) == .sent(parts: 0, list: true))
        var steps = 0
        while await uploader.catchUpStep([Self.listed(history)]) { steps += 1; #expect(steps < 20) }
        let pieces = service.calls.filter { $0.path == "/chats/piece" }
        #expect(pieces.first?.body["stream"] as? String == "read")
        let rawPieces = pieces.filter { $0.body["stream"] as? String == "raw" }.map { $0.body["rawLen"] as? Int }
        #expect(rawPieces == [4 * 1_048_576, 4 * 1_048_576])
        // The rest (under 4 MiB) comes with the next tick.
        _ = await uploader.round([Self.listed(history)])
        #expect(service.held("tab-1", "raw")?.bytes == (try Data(contentsOf: history)))
        let readable = String(decoding: service.held("tab-1", "read")?.bytes ?? Data(), as: UTF8.self).split(separator: "\n")
        #expect(readable.count == 4)
        // No call was ever bigger than the contract's 8 MiB.
        #expect(service.calls.allSatisfy { (try? JSONSerialization.data(withJSONObject: $0.body))?.count ?? 0 <= 8 * 1_048_576 })
    }

    @Test("A service without the routes: silent, nothing more is sent until the next launch")
    func serviceMissing() async throws {
        let service = FakeService(), dir = Self.folder(), history = dir.appendingPathComponent("c1.jsonl")
        service.routesMissing = true
        try Self.user(1).write(to: history, atomically: true, encoding: .utf8)
        let uploader = BackendCloudChatsUploader(send: service.send, directory: dir.appendingPathComponent("state"))
        #expect(await uploader.round([Self.listed(history)]) == .missing)
        #expect(await uploader.round([Self.listed(history)]) == .missing)
        #expect(await uploader.catchUpStep([Self.listed(history)]) == false)
        #expect(service.paths() == ["GET /chats/head"])
        #expect(await uploader.wire()["live"].bool == false)
    }

    @Test("An app chat's saved file goes up once it has been quiet 2 minutes, without its runtime fields")
    func appChatSnapWhenQuiet() async throws {
        let service = FakeService(), dir = Self.folder(), clock = Clock()
        let chat = dir.appendingPathComponent("chat.json")
        try #"{"version":1,"conversationId":"conv","busy":true,"events":[]}"#.write(to: chat, atomically: true, encoding: .utf8)
        let item = BackendCloudChats.Listed(row: .init(sessionId: "tab-chat", name: "Chat", lastUsedAt: 1, kind: "chat"),
                                            source: .init(readable: .appChat, snap: chat, provider: .claude))
        let uploader = BackendCloudChatsUploader(send: service.send, directory: dir.appendingPathComponent("state"), clock: clock.now)
        _ = await uploader.round([item])
        #expect(service.snaps["tab-chat"] == nil)
        clock.advance(BackendCloudChats.snapQuietMs)
        _ = await uploader.round([item])
        let sent = try #require(service.snaps["tab-chat"])
        #expect(String(decoding: sent, as: UTF8.self).contains("conv"))
        #expect(!String(decoding: sent, as: UTF8.self).contains("busy"))
    }

    @Test("The list row: the side panel's name, the contract's keys only, status in its words, the tab key as id")
    func listRow() throws {
        let row = BackendCloudChats.Row(sessionId: "tab-1", name: "CRM", lastUsedAt: 5, ai: "codex", kind: "agent", status: BackendCloudChats.status("input"))
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        #expect(Set(object.keys).isSubset(of: ["sessionId", "name", "lastUsedAt", "project", "cwd", "ai", "login", "kind", "status", "startedAt", "conversationId", "codeAt", "v"]))
        #expect(object["status"] as? String == "needsYou")
        #expect(BackendCloudChats.status("working") == "running" && BackendCloudChats.status("exited") == "ended" && BackendCloudChats.status("waiting") == "idle")
    }

    // MARK: The id join (live use): the live list's `tab` and `machine`

    static func meta(id: String, tabKey: String?) -> BackendSessionMeta {
        BackendSessionMeta(id: id, input: .init(cwd: "/tmp/p", provider: "claude"),
                           spawn: .init(provider: "claude", command: "/never-run", args: [], path: "/usr/bin", tabKey: tabKey),
                           now: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("A live row with a saved tab carries `tab` = its Cloud row's id; without one there is no field; the rest is byte-for-byte as before")
    func liveRowTab() throws {
        let before = NativeRPCValue.object([.init("id", .string("p-1")), .init("title", .string("p")), .init("cwd", .string("/tmp/p")),
            .init("provider", .string("claude")), .init("status", .string("idle")), .init("exitCode", .null), .init("lastActivityAt", .number(5))])
        let tabbed = Self.meta(id: "p-1", tabKey: "tab-1")
        let listed = BackendCloudChatsListedSession(meta: tabbed, status: "idle", lastUsedAt: 5)
        let cloudRow = BackendCloudChats.row(listed, name: nil, projects: [])
        let row = BackendRemoteHost.withTab(before, tabbed)
        #expect(row["tab"].string == cloudRow.sessionId)
        #expect(row["tab"].string == "tab-1")
        #expect(try BackendRemoteJSON.write(row.removing("tab")) == BackendRemoteJSON.write(before))
        #expect(row.fields?.last?.key == "tab")

        for key in [nil, "", "  "] as [String?] {
            let plain = Self.meta(id: "p-2", tabKey: key)
            let same = BackendRemoteHost.withTab(before, plain)
            #expect(same["tab"] == .missing)
            #expect(try BackendRemoteJSON.write(same) == BackendRemoteJSON.write(before))
            #expect(BackendCloudChats.cloudID(plain) == "p-2", "the clients' fallback: the Cloud id is the live id")
        }
    }

    @Test("The live list's header names this Mac by the Cloud's `machine` while signed in, and not at all otherwise")
    func liveListMachine() {
        let ref = BackendCloudChats.machineRef(subject: "sub-1", machine: "m-1")
        #expect(ref.count == 32 && ref.allSatisfy(\.isHexDigit))
        #expect(ref != BackendCloudChats.machineRef(subject: "sub-2", machine: "m-1"))
        let fields: [NativeRPCValue.Field] = [.init("sessions", .array([]))]
        BackendCloudChatsMachine.shared.set(nil)
        #expect(BackendRemoteHost.withMachine(fields).map(\.key) == ["sessions"])
        BackendCloudChatsMachine.shared.set(ref)
        defer { BackendCloudChatsMachine.shared.set(nil) }
        let header = BackendRemoteHost.withMachine(fields)
        #expect(header.map(\.key) == ["sessions", "machine"])
        #expect(header.last?.value.string == ref)
    }

    // MARK: Earlier chats (Terminal Deck's own past sessions)

    @Test("An old history in Terminal Deck's own login folder becomes an earlier chat of its project; a helper agent's does not")
    func oldHistoryBecomesEarlierChat() async throws {
        let service = FakeService(), dir = Self.folder(), clock = Clock()
        let home = dir.appendingPathComponent("account-logins/work", isDirectory: true)
        let folder = home.appendingPathComponent("projects/-Users-sam-Code-crm", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("0b1c/subagents"), withIntermediateDirectories: true)
        let history = folder.appendingPathComponent("0b1c.jsonl")
        let lines = #"{"type":"user","message":{"role":"user","content":"Fix the invoice totals before Friday please"},"uuid":"u1","timestamp":"2026-10-02T09:00:00.000Z","sessionId":"0b1c","cwd":"/Users/sam/Code/crm"}"# + "\n"
            + #"{"type":"assistant","message":{"id":"m1","model":"claude-opus","content":[{"type":"text","text":"Done."}]},"uuid":"a1","timestamp":"2026-10-02T09:05:00.000Z","sessionId":"0b1c","cwd":"/Users/sam/Code/crm"}"# + "\n"
        try lines.write(to: history, atomically: true, encoding: .utf8)
        // Helper agents' histories: one level deeper (today's Claude) and an `agent-` file of side chains (older Claude).
        try lines.write(to: folder.appendingPathComponent("0b1c/subagents/agent-a1.jsonl"), atomically: true, encoding: .utf8)
        try lines.replacingOccurrences(of: #""type":"user","#, with: #""type":"user","isSidechain":true,"#)
            .write(to: folder.appendingPathComponent("agent-old.jsonl"), atomically: true, encoding: .utf8)
        let projects = home.appendingPathComponent("projects")
        #expect(BackendCloudChatsArchive.isClaudeHistory(history, projects: projects))
        #expect(!BackendCloudChatsArchive.isClaudeHistory(folder.appendingPathComponent("0b1c/subagents/agent-a1.jsonl"), projects: projects))
        #expect(!BackendCloudChatsArchive.isClaudeHistory(folder.appendingPathComponent("agent-old.jsonl"), projects: projects))

        let found = BackendCloudChatsArchive.scan(homes: [home], chats: nil, skip: [])
        #expect(found.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path } == [history.resolvingSymlinksInPath().path])   // /var is /private/var
        let one = try #require(found.first)
        #expect(one.name == "Fix the invoice totals before Friday please")
        #expect(one.cwd == "/Users/sam/Code/crm")
        #expect(one.lastUsedAt == 1_790_931_900_000) // the history's own last turn, 2 Oct 09:05 UTC
        // A name the app still keeps for that conversation wins over the first words.
        #expect(BackendCloudChatsArchive.scan(homes: [home], chats: nil, skip: [], knownNames: ["0b1c": "Invoices"]).first?.name == "Invoices")

        let uploader = BackendCloudChatsUploader(send: service.send, directory: dir.appendingPathComponent("state"), clock: clock.now)
        await uploader.addArchive(found, salt: "mac-1", projects: [PROJProject(id: "crm", name: "CRM", folders: ["/Users/sam/Code/crm"])])
        // Introduced once with its project, name and dates, then taken off the list: a closed session's chat.
        _ = await uploader.round([])
        let introduced = try #require(service.lists.last?.first)
        #expect((introduced["project"] as? [String: Any])?["cloudRef"] as? String == "crm")
        #expect(introduced["status"] as? String == "ended" && introduced["name"] as? String == one.name)
        let id = try #require(introduced["sessionId"] as? String)
        clock.advance(BackendCloudChats.listEveryMs)
        _ = await uploader.round([])
        #expect(service.lists.last?.isEmpty == true)
        // Then copied in the background: readable copy first, then the history to the byte.
        while await uploader.catchUpStep([]) {}
        let pieces = service.calls.filter { $0.path == "/chats/piece" }.map { $0.body["stream"] as? String }
        #expect(pieces == ["read", "raw"])
        #expect(service.held(id, "raw")?.bytes == (try Data(contentsOf: history)))
        #expect(await uploader.state.archive[id]?.stage == .done)
        // Found again later: already known, nothing new.
        #expect(BackendCloudChatsArchive.scan(homes: [home], chats: nil, skip: await uploader.archiveSkip()).isEmpty)
    }

    // MARK: Deleting a chat (the delete rule)

    @Test("A deleted chat goes to the Bin (Everywhere only), stops being copied, and comes back with Put back all")
    func deletedChatIsInBinAndComesBack() async throws {
        let service = FakeService(), dir = Self.folder(), history = dir.appendingPathComponent("c1.jsonl")
        try Self.user(1).write(to: history, atomically: true, encoding: .utf8)
        let uploader = BackendCloudChatsUploader(send: service.send, directory: dir.appendingPathComponent("state"))
        _ = await uploader.round([Self.listed(history)])
        let owner = BackendCloudChatsDeleteOwner(bin: { ref, session, action in await uploader.bin(session: session, ref: ref, action: action) },
                                                 file: dir.appendingPathComponent("bin.json"))
        // The page's row: the existing row shape, one bin button.
        let row = BackendCloudSessionsRead.Row(ref: "ref-1", name: "CRM", lastUsedAt: 5, project: .init(cloudRef: "crm", name: "CRM"), ai: "claude",
                                               machineName: "Mac mini", machineOn: true, mine: true)
        let item = try #require(BackendCloudChatsContents.items([row]).first)
        #expect(item.kind == .sessions && item.canRemove && item.place == "CRM")
        #expect(BackendCloudDeletePage.scopes(for: [.sessions], gateOpen: true) == [.everywhere])
        #expect(BackendCloudDeletePage.kind(item.deleteItems[0]) == .sessions)
        let target = CloudDeleteItem(id: "ref-1", kind: BackendCloudChatsDeleteOwner.kind, name: "CRM", place: "tab-1")
        #expect(item.deleteItems == [CloudDeleteItem(id: "ref-1", kind: "chat", name: "CRM", place: nil)])

        let actor = CloudDeleteActor(by: .person, mac: "m1", macName: "Mac mini", at: Int64(Date().timeIntervalSince1970 * 1000), group: "g1")
        let group = try await owner.deleteItems([target], scope: .everywhere, by: actor)
        #expect(group.items == [target] && group.title == "Removed on Mac mini")
        #expect(service.binned["ref-1"] == "bin")
        #expect(try await owner.binGroups().map(\.id) == ["g1"])
        // Binned: this Mac copies nothing more of it, even when it grows.
        try Self.append(Self.assistant(1), to: history)
        service.calls = []
        _ = await uploader.round([Self.listed(history)])
        #expect(!service.calls.contains { ($0.body["parts"] as? [[String: Any]])?.isEmpty == false })
        // Put back all.
        #expect(try await owner.putBackGroup("g1") == [target])
        #expect(service.binned["ref-1"] == nil)
        #expect(try await owner.binGroups().isEmpty)
        #expect(await uploader.state.sessions["tab-1"]?.binned == false)
    }
}

// MARK: Live use from another Mac (15 Nov, live-use-plan.md): a Cloud row and its live session are ONE session

extension CloudChatsTests {
    static func links(_ machine: String? = "0123456789abcdef0123456789abcdef", state: String = "online", name: String = "Mac mini",
                      rows: [[String: Any]]) -> MachinesSnapshot {
        var link: [String: Any] = ["id": "reach-m1", "state": state, "sessions": rows]
        if let machine { link["machine"] = machine }
        return MachinesSnapshot.decode(["machines": [["id": "reach-m1", "name": name, "reach": true]], "links": [link]])!
    }

    @Test("The live twin: same machine by its ref, same session by its tab (else its own id); a machine that is not online has none")
    func liveTwinJoin() {
        let rows: [[String: Any]] = [["id": "p1", "title": "Claude", "cwd": "/w", "provider": "claude", "status": "idle", "tab": "tab-1"],
                                     ["id": "p2", "title": "Shell", "cwd": "/w", "provider": "shell", "status": "idle"],
                                     ["id": "c9", "title": "Plan", "cwd": "/w", "provider": "claude", "status": "idle", "chat": true]]
        let snapshot = Self.links(rows: rows)
        let ref = "0123456789abcdef0123456789abcdef"
        #expect(snapshot.liveTwin(sessionId: "tab-1", machineRef: ref, machineName: "x")?.tabId == "machine reach-m1 p1")
        #expect(snapshot.liveTwin(sessionId: "p2", machineRef: ref, machineName: nil)?.session.id == "p2")
        // A row that has a tab is never matched by its process id (that id is not its Cloud id).
        #expect(snapshot.liveTwin(sessionId: "p1", machineRef: ref, machineName: nil) == nil)
        #expect(snapshot.liveTwin(sessionId: "c9", machineRef: ref, machineName: nil)?.session.chat == true)
        // Another machine's ref: no twin, even with the same name.
        #expect(snapshot.liveTwin(sessionId: "tab-1", machineRef: "ffffffffffffffffffffffffffffffff", machineName: "Mac mini") == nil)
        // An older machine that says no ref: matched by its name.
        #expect(Self.links(nil, rows: rows).liveTwin(sessionId: "tab-1", machineRef: ref, machineName: "Mac mini.local")?.session.id == "p1")
        // Off or reconnecting: the page stays the Cloud copy.
        #expect(Self.links(state: "connecting", rows: rows).liveTwin(sessionId: "tab-1", machineRef: ref, machineName: "Mac mini") == nil)
        #expect(snapshot.names["reach-m1"] == "Mac mini")
        // A machine paired by code is never his session's live copy, even claiming his ref and name (Reviewer, 15 Nov).
        let paired = MachinesSnapshot.decode(["machines": [["id": "paired-1", "name": "Mac mini"]],
                                              "links": [["id": "paired-1", "state": "online", "machine": ref, "sessions": rows]]])!
        #expect(paired.liveTwin(sessionId: "tab-1", machineRef: ref, machineName: "Mac mini") == nil)
    }

    @Test("A machine reached by sign-in is not listed among the paired ones, but its name is known to its sessions")
    func reachRowsStayOffThePairedList() {
        let raw: [String: Any] = ["machines": [["id": "paired-1", "name": "Old PC"], ["id": "reach-m1", "name": "Mac mini", "reach": true]], "links": []]
        #expect(MachinesView(json: raw).machines.map(\.id) == ["paired-1"])
        #expect(MachinesSnapshot.decode(raw)?.names["reach-m1"] == "Mac mini")
    }
}
