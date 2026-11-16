import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Mac shelf (owner, 15 Nov: phones show his Cloud content when no Mac is on; "I need every single thing in cloud"):
/// only kinds whose view changed are put; texts only when the service asks; never-served kinds, the Bin and "Only on
/// this Mac" items never leave; `shelf_behind` does nothing; a lost connection resumes; the setting off stops; a
/// service without the routes is silent. A stand-in service plays the contract (Servers note part 7).
@Suite("Cloud shelf: what the phones show when the Macs are off")
struct CloudShelfTests {
    typealias Kind = BackendCloudContents.Kind
    typealias Shelf = BackendCloudShelf

    /// The contract's service, kept small: lists per kind, texts by hash, the setting, and switches for its answers.
    final class FakeService: @unchecked Sendable {
        let lock = NSLock()
        var calls: [(method: String, path: String, body: [String: Any])] = []
        var lists: [String: (putId: String, rows: [[String: Any]])] = [:]
        var staged: [String: [[String: Any]]] = [:]
        var texts: Set<String> = []
        var on = true
        var routesMissing = false
        var behind = false
        var dropTexts = false
        func paths() -> [String] { lock.withLock { calls.map { $0.method + " " + $0.path } } }
        func clear() { lock.withLock { calls = [] } }
        func json(_ value: Any) -> Data { (try? JSONSerialization.data(withJSONObject: value)) ?? Data() }
        func refuse(_ status: Int, _ code: String) -> (status: Int, data: Data) { (status, json(["error": ["code": code, "message": code, "retryable": false, "requestId": "r"]])) }
        func needTexts(_ kind: String) -> [String] {
            Array(Set((lists[kind]?.rows ?? []).compactMap { $0["textHash"] as? String }.filter { !texts.contains($0) })).sorted()
        }
        var send: BackendCloudShelfPutter.Send {
            { [self] method, path, body in try self.answer(method, path, body) }
        }
        func answer(_ method: String, _ path: String, _ body: Data) throws -> (status: Int, data: Data) {
            try lock.withLock {
                let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
                calls.append((method, path, object))
                if routesMissing { return refuse(404, "not_found") }
                if method == "GET", path.hasPrefix("/shelf") {
                    let kind = path.components(separatedBy: "kind=").dropFirst().first
                    var made: [String: Any] = ["on": on, "kinds": lists.map { ["kind": $0.key, "putId": $0.value.putId, "asOf": 1_000, "fromDevice": "Studio Mac", "count": $0.value.rows.count] }]
                    if let kind { made["needTexts"] = needTexts(kind) }
                    return (200, json(made))
                }
                if path == "/shelf/setting" {
                    on = object["on"] as? Bool ?? on
                    if !on { lists = [:]; texts = [] }
                    return (200, json(["on": on]))
                }
                guard on else { return refuse(409, "shelf_off") }
                if path == "/shelf/list" {
                    if behind { return refuse(409, "shelf_behind") }
                    let kind = object["kind"] as! String, putId = object["putId"] as! String
                    let part = object["part"] as! Int, parts = object["parts"] as! Int
                    let rows = object["items"] as? [[String: Any]] ?? []
                    staged[putId, default: []] += rows
                    guard part == parts - 1 else { return (200, json(["accepted": false, "waiting": parts - 1 - part])) }
                    lists[kind] = (putId, staged[putId] ?? [])
                    staged[putId] = nil
                    return (200, json(["accepted": true, "asOf": 2_000, "count": lists[kind]!.rows.count, "dropped": 0, "needTexts": needTexts(kind)]))
                }
                if path == "/shelf/texts" {
                    if dropTexts { throw URLError(.networkConnectionLost) }
                    for piece in object["texts"] as? [[String: Any]] ?? [] { if let hash = piece["hash"] as? String { texts.insert(hash) } }
                    return (200, json(["stored": [], "refused": []]))
                }
                return refuse(404, "not_found")
            }
        }
    }

    // MARK: Review N2 (15 Nov): free text never leaves as a setting value; whole-word secret names; task texts

    @Test("a setting's value leaves only as on/off, a number or a fixed choice; typed text is listed by name only")
    func settingsValuesOnlyFixedKinds() async {
        func row(_ id: String, _ name: String, _ value: String) -> BackendCloudContents.Item {
            var made = Self.item("settings|setting:" + id, .settings, name); made.folder = ["General"]; made.value = value; return made
        }
        let items = [row("general.sounds", "Sounds", "On"), row("general.limit", "Routine limit", "12"),
                     row("appearance.theme", "Theme", "Dark"),
                     row("browser.startPage", "Start page", "Example.com/start?made-up=1"),
                     row("server.proxy", "Proxy", "Made-up user at proxy"),
                     row("keyboard.layout", "Keyboard", "Off")]
        let rows = Self.rows(items)[.settings] ?? []
        func status(_ name: String) -> String? { rows.first { $0.name == name }?.status }
        #expect(status("Sounds") == "On" && status("Routine limit") == "12" && status("Theme") == "Dark")
        #expect(status("Start page") == nil && status("Proxy") == nil)
        #expect(rows.contains { $0.name == "Start page" } && rows.contains { $0.name == "Proxy" })   // listed by name
        #expect(status("Keyboard") == "Off")                                                           // "key" only as a whole word
        let all = String(decoding: (try? JSONEncoder().encode(rows)) ?? Data(), as: UTF8.self)
        #expect(!all.contains("made-up=1") && !all.contains("Made-up user"))
    }

    @Test("secret words count as whole words, also in camelCase and joined forms")
    func secretNamesAreWholeWords() {
        func secret(_ id: String, _ name: String) -> Bool { Shelf.holdsSecret(Self.item("settings|setting:" + id, .settings, name)) }
        #expect(secret("openai.apiKey", "OpenAI API key") && secret("github.token", "GitHub token") && secret("x.auth_token", "Sign-in"))
        #expect(!secret("keyboard.layout", "Keyboard") && !secret("app.monkeys", "Monkeys"))
    }

    @Test("a task text holding a known secret is not put on the shelf")
    func taskTextWithASecretStaysOff() {
        var plain = TaskRow(id: "t1", title: "Plain"); plain.instructions = "Write the release notes."
        #expect(Shelf.taskText(plain) == "Write the release notes.")
        var leaky = TaskRow(id: "t2", title: "Leaky"); leaky.instructions = "Use AKIA" + String(repeating: "Z", count: 16) + " for the upload."
        #expect(Shelf.taskText(leaky) == nil)
    }

    static func item(_ id: String, _ kind: Kind, _ name: String, at: Int64 = 1_700_000_000_000, text: Bool = false) -> BackendCloudContents.Item {
        var made = BackendCloudContents.Item(id: id, kind: kind, name: name, place: nil, changedBy: "Studio Mac", changedAt: at, presence: [],
                                             onDevices: [], history: [], bytes: 10, entries: nil, note: nil, isText: text)
        made.canOpen = text
        return made
    }
    static func rows(_ items: [BackendCloudContents.Item], texts: [String: String] = [:]) -> [Kind: [Shelf.Row]] {
        let model = BackendCloudContents(devices: [], counts: [:], items: items, activity: [])
        var made: [Kind: [Shelf.Row]] = [:]
        for (kind, entries) in Shelf.entries(model: model) {
            made[kind] = entries.map { entry in
                var row = entry.row
                if let id = entry.textItem, let text = texts[id] {
                    let fact = Shelf.fact(text)
                    row.textHash = fact.hash; row.textBytes = fact.bytes; row.textPieces = fact.pieces
                }
                return row
            }
        }
        return made
    }
    static func textOf(_ texts: [String: String]) -> @Sendable (String) async -> String? {
        let byHash = Dictionary(texts.values.map { (Shelf.hash(Data($0.utf8)), $0) }, uniquingKeysWith: { first, _ in first })
        return { hash in byHash[hash] }
    }
    static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cloud-shelf-tests-" + UUID().uuidString).appendingPathComponent("shelf.json")
    }

    @Test("only kinds whose view changed are put")
    func onlyChangedKinds() async {
        let service = FakeService()
        let putter = BackendCloudShelfPutter(send: service.send, file: Self.scratch())
        var items = [Self.item("tasks||Ship", .tasks, "Ship the shelf"), Self.item("projects||Deck", .projects, "Deck")]
        var rows = Self.rows(items)
        for kind in Shelf.servedKinds { _ = await putter.put(kind, rows: rows[kind] ?? [], throughSeq: "5", from: "Studio Mac", text: Self.textOf([:])) }
        #expect(service.paths().filter { $0 == "POST /shelf/list" }.count == Shelf.servedKinds.count)
        service.clear()
        for kind in Shelf.servedKinds {
            #expect(await putter.put(kind, rows: rows[kind] ?? [], throughSeq: "6", from: "Studio Mac", text: Self.textOf([:])) == .unchanged)
        }
        #expect(service.paths().isEmpty)
        items[0] = Self.item("tasks||Ship", .tasks, "Ship the shelf", at: 1_700_000_100_000)
        rows = Self.rows(items)
        for kind in Shelf.servedKinds { _ = await putter.put(kind, rows: rows[kind] ?? [], throughSeq: "7", from: "Studio Mac", text: Self.textOf([:])) }
        #expect(service.paths() == ["POST /shelf/list"])
        #expect(service.calls.first?.body["kind"] as? String == "tasks")
    }

    @Test("a changed view goes up only after it stayed the same for 30 s, at launch too")
    func settleAtLaunchToo() {
        let now: Int64 = 1_800_000_000_000
        // First sight (the launch view while another Mac's changes are still arriving): wait.
        #expect(!Shelf.settled(held: nil, fingerprint: "a", now: now))
        // The view moved during the wait (12 tasks became 21): the wait starts again.
        #expect(!Shelf.settled(held: ("a", now - 40_000), fingerprint: "b", now: now))
        #expect(!Shelf.settled(held: ("b", now - 29_999), fingerprint: "b", now: now))
        #expect(Shelf.settled(held: ("b", now - 30_000), fingerprint: "b", now: now))
    }

    @Test("a round that never returns stops the shelf for at most 10 minutes")
    func stuckRoundDoesNotStopTheShelf() {
        let now: Int64 = 1_800_000_000_000
        #expect(Shelf.roundMayStart(running: nil, now: now))
        #expect(!Shelf.roundMayStart(running: now - 60_000, now: now))
        #expect(!Shelf.roundMayStart(running: now - Shelf.roundStuckMs + 1, now: now))
        #expect(Shelf.roundMayStart(running: now - Shelf.roundStuckMs, now: now))
    }

    @Test("a later put of the whole view replaces a short one put earlier by another Mac")
    func fullViewReplacesShort() async {
        let service = FakeService()
        let early = BackendCloudShelfPutter(send: service.send, file: Self.scratch())
        let short = Self.rows((0..<12).map { Self.item("tasks||T\($0)", .tasks, "Task \($0)") })
        let whole = Self.rows((0..<21).map { Self.item("tasks||T\($0)", .tasks, "Task \($0)") })
        #expect(await early.put(.tasks, rows: short[.tasks] ?? [], throughSeq: "2568", from: "MacBook", text: Self.textOf([:])) != .unchanged)
        // The same Mac, once its view settled with everything that arrived: its whole list goes up again.
        #expect(await early.put(.tasks, rows: whole[.tasks] ?? [], throughSeq: "2575", from: "MacBook", text: Self.textOf([:])) != .unchanged)
        #expect(service.lists["tasks"]?.rows.count == 21)
        #expect(await early.state.kinds["tasks"]?.count == 21)
    }

    @Test("the diary's count moving with every message does not make a put by itself")
    func diaryChurn() async {
        let service = FakeService()
        let putter = BackendCloudShelfPutter(send: service.send, file: Self.scratch())
        func diary(_ entries: Int, at: Int64) -> BackendCloudContents.Item {
            BackendCloudContents.Item(id: "memory|table|Diary", kind: .memory, name: "Diary", place: nil, changedBy: "Studio Mac", changedAt: at,
                                      presence: [], onDevices: [], history: [], bytes: Int64(entries * 100), entries: entries, note: nil, isText: false)
        }
        let first = Self.rows([diary(100, at: 1)])[.memory]!
        #expect(first.first?.status == "100 entries")
        _ = await putter.put(.memory, rows: first, throughSeq: "1", from: nil, text: Self.textOf([:]))
        service.clear()
        #expect(await putter.put(.memory, rows: Self.rows([diary(101, at: 2)])[.memory]!, throughSeq: "2", from: nil, text: Self.textOf([:])) == .unchanged)
        #expect(service.paths().isEmpty)
    }

    @Test("texts only when the service asks for them")
    func textsOnlyWhenAsked() async {
        let service = FakeService()
        let putter = BackendCloudShelfPutter(send: service.send, file: Self.scratch())
        var texts = ["memory||Plan": "The plan.", "memory||Notes": "Some notes."]
        var items = [Self.item("memory||Plan", .memory, "Plan", text: true), Self.item("memory||Notes", .memory, "Notes", text: true)]
        _ = await putter.put(.memory, rows: Self.rows(items, texts: texts)[.memory]!, throughSeq: "5", from: nil, text: Self.textOf(texts))
        let first = service.calls.filter { $0.path == "/shelf/texts" }.flatMap { $0.body["texts"] as? [[String: Any]] ?? [] }
        #expect(first.count == 2)
        service.clear()
        // One note changes: its new text is the only one sent.
        texts["memory||Plan"] = "The plan, changed."
        items[0] = Self.item("memory||Plan", .memory, "Plan", at: 1_700_000_200_000, text: true)
        _ = await putter.put(.memory, rows: Self.rows(items, texts: texts)[.memory]!, throughSeq: "6", from: nil, text: Self.textOf(texts))
        let second = service.calls.filter { $0.path == "/shelf/texts" }.flatMap { $0.body["texts"] as? [[String: Any]] ?? [] }
        #expect(second.count == 1)
        #expect(second.first?["text"] as? String == "The plan, changed.")
        // A kind without texts never sends one.
        service.clear()
        _ = await putter.put(.projects, rows: Self.rows([Self.item("projects||A", .projects, "A project", text: true)])[.projects]!, throughSeq: "7", from: nil, text: Self.textOf(texts))
        #expect(!service.paths().contains("POST /shelf/texts"))
    }

    @Test("never-served kinds, the Bin, Only on this Mac and unsent items never leave")
    func neverLeaves() {
        var bin = Self.item("memory|bin|old.md", .memory, "Old note"); bin.state = .inBin(removedAt: 1)
        var only = Self.item("memory||Private", .memory, "Private"); only.localMark = .onlyOnThisMac
        var notHere = Self.item("cloudFolder||a.pdf", .cloudFolder, "a.pdf"); notHere.localMark = .notOnThisMac
        var sending = Self.item("tasks||Sending", .tasks, "Sending"); sending.standing = .sending
        var refused = Self.item("tasks||Refused", .tasks, "Refused"); refused.standing = .notSent
        var waiting = Self.item("tasks||Waiting", .tasks, "Waiting"); waiting.standing = .waitingHere
        let items = [Self.item("passwords||GitHub", .passwords, "GitHub"), Self.item("settings||Yours", .settings, "Your settings"),
                     Self.item("other||x", .other, "Item"), bin, only, notHere, sending, refused, waiting,
                     Self.item("memory||Code", .memory, "0123456789abcdef0123"), Self.item("agents||Hoot", .agents, "Hoot")]
        let rows = Self.rows(items)
        #expect(Set(rows.keys) == Set(Shelf.servedKinds))
        let names = rows.values.flatMap { $0.map(\.name) }
        // Slice 2: settings are served now (one row per setting).
        #expect(Set(names) == ["Waiting", "Hoot", "Your settings"])
        #expect(!rows.keys.contains(.passwords) && !rows.keys.contains(.other))
    }

    @Test("shelf_behind: another Mac's newer view stands, nothing is done")
    func behind() async {
        let service = FakeService()
        service.behind = true
        let putter = BackendCloudShelfPutter(send: service.send, file: Self.scratch())
        let texts = ["memory||Plan": "The plan."]
        let rows = Self.rows([Self.item("memory||Plan", .memory, "Plan", text: true)], texts: texts)[.memory]!
        #expect(await putter.put(.memory, rows: rows, throughSeq: "3", from: nil, text: Self.textOf(texts)) == .behind)
        #expect(service.paths() == ["POST /shelf/list"])
        service.clear()
        #expect(await putter.put(.memory, rows: rows, throughSeq: "3", from: nil, text: Self.textOf(texts)) == .unchanged)
        #expect(service.paths().isEmpty)
    }

    @Test("a lost connection while sending texts resumes from the service's needTexts, without a new list")
    func resume() async {
        let service = FakeService()
        let file = Self.scratch()
        let texts = ["memory||Plan": "The plan.", "memory||Notes": "Some notes."]
        let rows = Self.rows([Self.item("memory||Plan", .memory, "Plan", text: true), Self.item("memory||Notes", .memory, "Notes", text: true)], texts: texts)[.memory]!
        service.dropTexts = true
        _ = await BackendCloudShelfPutter(send: service.send, file: file).put(.memory, rows: rows, throughSeq: "5", from: nil, text: Self.textOf(texts))
        #expect(service.texts.isEmpty)
        // The app starts again: the same state file, the connection back.
        service.dropTexts = false
        service.clear()
        let again = BackendCloudShelfPutter(send: service.send, file: file)
        #expect(await again.state.kinds["memory"]?.textsOwed == true)
        _ = await again.put(.memory, rows: rows, throughSeq: "5", from: nil, text: Self.textOf(texts))
        #expect(service.paths() == ["GET /shelf?kind=memory", "POST /shelf/texts"])
        #expect(service.texts.count == 2)
        #expect(await again.state.kinds["memory"]?.textsOwed == false)
    }

    @Test("the setting off empties the shelf and stops putting")
    func settingOff() async {
        let service = FakeService()
        let putter = BackendCloudShelfPutter(send: service.send, file: Self.scratch())
        let rows = Self.rows([Self.item("projects||Deck", .projects, "Deck")])[.projects]!
        _ = await putter.put(.projects, rows: rows, throughSeq: "1", from: nil, text: Self.textOf([:]))
        await putter.setOn(false)
        #expect(service.on == false && service.lists.isEmpty)
        service.clear()
        #expect(await putter.put(.projects, rows: rows, throughSeq: "2", from: nil, force: true, text: Self.textOf([:])) == .off)
        #expect(service.paths().isEmpty)
        // Turned off on another device: the service's shelf_off stops this Mac too.
        let other = BackendCloudShelfPutter(send: service.send, file: Self.scratch())
        #expect(await other.put(.projects, rows: rows, throughSeq: "2", from: nil, text: Self.textOf([:])) == .off)
        #expect(await other.state.on == false)
    }

    @Test("a service without the shelf routes: silent, nothing more is sent")
    func serviceMissing() async {
        let service = FakeService()
        service.routesMissing = true
        let putter = BackendCloudShelfPutter(send: service.send, file: Self.scratch())
        let rows = Self.rows([Self.item("projects||Deck", .projects, "Deck")])[.projects]!
        #expect(await putter.status() == nil)
        #expect(await putter.put(.projects, rows: rows, throughSeq: "1", from: nil, text: Self.textOf([:])) == .missing)
        #expect(await putter.put(.tasks, rows: [], throughSeq: "1", from: nil, text: Self.textOf([:])) == .missing)
        #expect(service.paths() == ["GET /shelf"])
    }

    @Test("long texts in pieces under 256 KiB, long lists in parts of 500")
    func piecesAndParts() async {
        let long = String(repeating: "é note ", count: 60_000)
        let pieces = Shelf.pieces(long)
        #expect(pieces.count > 1 && pieces.allSatisfy { $0.utf8.count <= Shelf.pieceBytes } && pieces.joined() == long)
        #expect(Shelf.pieces("") == [""])
        let service = FakeService()
        let putter = BackendCloudShelfPutter(send: service.send, file: Self.scratch())
        let many = (0..<1_200).map { Shelf.Row(key: "tasks||Task \($0)", name: "Task \($0)", changedAt: 1) }
        #expect(await putter.put(.tasks, rows: many, throughSeq: "9", from: nil, text: Self.textOf([:])) == .put(count: 1_200, texts: 0))
        let lists = service.calls.filter { $0.path == "/shelf/list" }
        #expect(lists.count == 3 && Set(lists.compactMap { $0.body["putId"] as? String }).count == 1)
    }

    // MARK: Slice 2 (review-fixes set 3): settings rows, task / Cloud folder / artifact texts

    @Test("settings rows carry their page and value; a secret setting is listed by name with no value")
    func settingsRows() async {
        var theme = Self.item("settings|setting:appearance.theme", .settings, "Theme")
        theme.folder = ["Appearance"]; theme.value = "Dark"
        var token = Self.item("settings|setting:github.token", .settings, "GitHub token")
        token.folder = ["Accounts"]; token.value = "ghp_made-up-not-a-real-token"
        var apiKey = Self.item("settings|setting:openai.apiKey", .settings, "OpenAI API key")
        apiKey.folder = ["Coding AIs"]; apiKey.value = "sk-made-up"
        let rows = Self.rows([theme, token, apiKey])[.settings] ?? []
        #expect(rows.count == 3)
        let shown = rows.first { $0.name == "Theme" }
        #expect(shown?.place == "Appearance")
        #expect(shown?.status == "Dark")
        #expect(shown?.textHash == nil)
        for secret in rows where secret.name != "Theme" {
            #expect(secret.status == nil)
            #expect(secret.place != nil)
        }
        let all = String(decoding: (try? JSONEncoder().encode(rows)) ?? Data(), as: UTF8.self)
        #expect(!all.contains("ghp_") && !all.contains("sk-made-up"))
        // Put once; unchanged settings are not put again.
        let service = FakeService()
        let putter = BackendCloudShelfPutter(send: service.send, file: Self.scratch())
        #expect(await putter.put(.settings, rows: rows, throughSeq: "1", from: nil, text: Self.textOf([:])) == .put(count: 3, texts: 0))
        service.clear()
        #expect(await putter.put(.settings, rows: rows, throughSeq: "2", from: nil, text: Self.textOf([:])) == .unchanged)
        #expect(service.paths().isEmpty)
    }

    @Test("a task, a Cloud folder and an artifact text is put; a binary file is listed without one")
    func slice2Texts() async {
        let task = Self.item("tasks||Ship", .tasks, "Ship the shelf")   // a task is never `isText`; it still carries its text
        let note = Self.item("cloudFolder||notes.md", .cloudFolder, "notes.md", text: true)
        var page = Self.item("artifacts||report.html", .artifacts, "report.html", text: true); page.canOpen = false
        let picture = Self.item("cloudFolder||photo.png", .cloudFolder, "photo.png")
        let texts = ["tasks||Ship": "Make the shelf carry tasks.\n\nDecker: done", "cloudFolder||notes.md": "Notes.", "artifacts||report.html": "<p>Report</p>"]
        let rows = Self.rows([task, note, page, picture], texts: texts)
        #expect(rows[.tasks]?.first?.textHash == Shelf.hash(Data(texts["tasks||Ship"]!.utf8)))
        #expect(rows[.cloudFolder]?.first { $0.name == "notes.md" }?.textHash != nil)
        #expect(rows[.artifacts]?.first?.textHash != nil, "an artifact text goes even though the page does not open it")
        let png = rows[.cloudFolder]?.first { $0.name == "photo.png" }
        #expect(png?.binary == true && png?.textHash == nil)
        let service = FakeService()
        let putter = BackendCloudShelfPutter(send: service.send, file: Self.scratch())
        for kind in [Kind.tasks, .cloudFolder, .artifacts] {
            _ = await putter.put(kind, rows: rows[kind] ?? [], throughSeq: "1", from: nil, text: Self.textOf(texts))
        }
        let sent = service.calls.filter { $0.path == "/shelf/texts" }.flatMap { $0.body["texts"] as? [[String: Any]] ?? [] }
        #expect(Set(sent.compactMap { $0["text"] as? String }) == Set(texts.values))
        // Unchanged: nothing is put again, no text either.
        service.clear()
        for kind in [Kind.tasks, .cloudFolder, .artifacts] {
            #expect(await putter.put(kind, rows: rows[kind] ?? [], throughSeq: "2", from: nil, text: Self.textOf(texts)) == .unchanged)
        }
        #expect(service.paths().isEmpty)
    }

    @Test("open files: a state saved before loads as it was; a row without a file encodes as before; file items are marked")
    func openFilesKeepOldShape() async throws {
        let file = Self.scratch()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"on":false,"kinds":{"tasks":{"fingerprint":"abc","putAt":5,"count":1,"textsOwed":false}},"texts":{}}"#.utf8).write(to: file)
        let putter = BackendCloudShelfPutter(send: FakeService().send, file: file)
        #expect(await putter.state.on == false)
        #expect(await putter.state.kinds["tasks"]?.fingerprint == "abc")
        #expect(await putter.filesLive(.cloudFolder) == false)
        let row = Shelf.Row(key: "cloudFolder||a.png", name: "a.png", changedAt: 1, binary: true)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any] ?? [:]
        #expect(Set(object.keys) == ["key", "name", "changedAt", "binary"])
        let model = BackendCloudContents(devices: [], counts: [:], items: [Self.item("cloudFolder||a.png", .cloudFolder, "a.png"),
                                                                            Self.item("tasks||Ship", .tasks, "Ship")], activity: [])
        let entries = Shelf.entries(model: model)
        #expect(entries[.cloudFolder]?.first?.fileItem == "cloudFolder||a.png")
        #expect(entries[.tasks]?.first?.fileItem == nil)
    }

    @Test("the task text and the file reader: description and comments; text files up to 1 MB; never binary or a secret")
    func slice2Readers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-shelf-files-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("Plain words.".utf8).write(to: root.appendingPathComponent("docs/a.md"))
        try Data([0x89, 0x50, 0x4e, 0x47, 0x00, 0x01]).write(to: root.appendingPathComponent("b.png"))
        try Data(repeating: 0x61, count: Shelf.textMaxBytes + 1).write(to: root.appendingPathComponent("big.txt"))
        #expect(Shelf.fileText(root: root, relative: "docs/a.md") == "Plain words.")
        #expect(Shelf.fileText(root: root, relative: "b.png") == nil)
        #expect(Shelf.fileText(root: root, relative: "big.txt") == nil)
        #expect(Shelf.fileText(root: root, relative: "missing.md") == nil)
    }
}
