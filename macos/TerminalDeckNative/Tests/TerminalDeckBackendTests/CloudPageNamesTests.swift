import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Page-names lane (owner, 13 Nov, the two-Mac check): Settings → Cloud and the Your Cloud window show names and dates
/// only, one true number for each thing in both views, an optional feature as an offer, and never "Preparing" once
/// every change is prepared. Pure page models from realistic inputs; nothing is sent or read from disk.
@Suite("Cloud pages — names, one set of numbers, plain device cards")
struct CloudPageNamesTests {
    static let gate = CloudGate(features: ["cloud"], storageEntitled: true)
    static let mini = "33333333-3333-4333-8333-333333333333"
    static let book = "44444444-4444-4444-8444-444444444444"
    static let key = CloudPublicJWK(kty: "EC", crv: "P-256", x: "x", y: "y")
    let now: Int64 = 1_794_000_000_000

    /// The owner's rule as a test: no UUID, no run of 8+ hex characters, no dotted key name, no file name with the
    /// random ending the app adds.
    static func leak(_ text: String) -> String? {
        let patterns = [
            "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
            "[0-9a-fA-F]{8,}",
            "\\b[a-z][a-z0-9_-]*\\.[a-z][a-z0-9_.-]*[a-z0-9]\\b",
            "-[a-z0-9]{6}\\.md",
        ]
        return patterns.first { text.range(of: $0, options: .regularExpression) != nil }
    }
    static func texts(_ overview: BackendCloudOverview) -> [String] {
        [overview.title] + overview.lines + overview.waiting.map(\.text) + overview.notices.map(\.text)
            + overview.rows.flatMap { [$0.title, $0.state] + $0.notes }
    }
    static func texts(_ model: BackendCloudContents) -> [String] {
        model.devices.flatMap { [$0.name, $0.state] } + model.items.flatMap { [$0.name, $0.place ?? "", $0.note ?? ""] + $0.presence }
            + model.activity.map(\.text) + [model.catchingUp ?? "", model.arriving ?? ""] + model.kindLines.values
    }

    func device(_ id: String, _ label: String, seen: Int64, pulled: UInt64? = nil) -> CloudDevice {
        var made = CloudDevice(deviceId: id, label: label, platform: .macos, appVersion: "fixture", status: .active, secretsApproved: false,
                               lastSeenAt: seen, signPublicJwk: Self.key, wrapPublicJwk: Self.key, registeredAt: now - 86_400_000)
        made.lastPulledSeq = pulled.map { CloudSequence($0) }
        return made
    }
    func snapshot(coverage: [CloudCoverage] = [], baseline: CloudBaselineProgress? = nil, head: UInt64 = 400, fetched: UInt64 = 400,
                  bookPulled: UInt64? = 400, ownRowStale: Bool = false) -> CloudAccountSnapshot {
        var mine = CloudDeviceTrustRow(deviceId: Self.mini, name: "Mac mini", standing: .thisMac, code: "AAAA BBBB CCCC DDDD", keyId: "k1", signKey: Self.key)
        if ownRowStale { mine = CloudDeviceTrustRow(deviceId: Self.mini, name: "Mac mini", standing: .thisMac, code: nil, keyId: nil, signKey: nil, stale: true) }
        let other = CloudDeviceTrustRow(deviceId: Self.book, name: "MacBook Pro", standing: .trusted, code: "EEEE FFFF GGGG HHHH", keyId: "k2", signKey: Self.key)
        return CloudAccountSnapshot(phase: .signedIn, gate: Self.gate, displayName: "Fixture",
                                    devices: [device(Self.mini, "Mac mini", seen: now), device(Self.book, "MacBook Pro", seen: now - 60_000, pulled: bookPulled)],
                                    coverage: coverage, trust: [mine, other], baseline: baseline,
                                    cloudHead: CloudSequence(head), fetched: CloudSequence(fetched))
    }
    /// 57,000 sync records that are, in the person's words, 3,523 notes, 39,851 diary entries and 120 topics.
    var savedCoverage: [CloudCoverage] {
        [("I01", 3_523), ("I02", 39_851), ("I03", 9_000), ("I04", 2_000), ("I05", 2_506), ("I06", 120)].map { row, items in
            CloudCoverage(sourceId: "memory/" + row, inventoryRow: row, complete: true, items: items, bytes: 10, blockedReasons: [],
                          exclusions: row == "I05" ? DeckMemoryCloudSchema.unknownSettingNotes(Self.settingKeys) : [])
        }
    }
    static let settingKeys = ["desk.fill", "refresh.last", "rules.short-titles",
                              "task.thread.seen.82b2404e-2a14-4dfc-b12a-5f0534d6ec5b:c28a5c57-1d2e-4f30-9a1b-2c3d4e5f6a7b",
                              "task.thread.seen.0b9e8f7a-6d5c-4b3a-8291-0f1e2d3c4b5a:5a4b3c2d-1e0f-4a9b-8c7d-6e5f4a3b2c1d"]
    var counts: BackendCloudPageCounts {
        BackendCloudPageCounts(here: [.notes: 3_523, .diary: 39_851, .topics: 120, .settings: 11, .projects: 4, .agents: 77, .instructionFiles: 293])
    }
    func contents(diaryRows: Int = 5, pulledBy book: Bool = true) -> CloudSyncContents {
        typealias Key = CloudSyncContents.Key
        let note = Key(domain: "brain/memory/i01", sourceId: "memory/I01", recordId: "file/roles/decker/notes/2026-11-13-cloud-check-dtvjwi.md", projectId: nil)
        let diary = (0..<diaryRows).map { Key(domain: "brain/memory/i02", sourceId: "memory/I02", recordId: "row/diary/" + String(repeating: "ab", count: 32) + "\($0)", projectId: nil) }
        let items: [CloudSyncContents.Item] = [
            .init(key: note, changes: [.init(deviceId: Self.book, at: now - 300_000)], standing: .inCloud, seq: CloudSequence(390)),
        ] + diary.map { .init(key: $0, changes: [.init(deviceId: Self.mini, at: now - 600_000)], standing: .inCloud, seq: CloudSequence(380)) }
        let packs: [CloudSyncContents.Pack] = [
            .init(deviceId: Self.book, at: now - 300_000, arrivedAt: now - 290_000, keys: [note], count: ["brain/memory/i01": 1]),
            .init(deviceId: Self.mini, at: now - 600_000, arrivedAt: nil, keys: Array(diary.prefix(3)), count: ["brain/memory/i02": 256]),
        ]
        return CloudSyncContents(thisDevice: Self.mini, items: items, packs: packs)
    }

    /// PAGES-FIX-2: a device is named by its real name when the app knows it ("Asad’s MacBook Pro"); else by its
    /// trust-list name; never an id, a code or a blank.
    @Test func deviceNamesFallBackToTheTrustListNeverAnId() throws {
        let gone = "55555555-5555-4555-8555-555555555555", coded = "66666666-6666-4666-8666-666666666666"
        let mine = CloudDeviceTrustRow(deviceId: Self.mini, name: "Mac mini", standing: .thisMac, code: "AAAA BBBB CCCC DDDD", keyId: "k1", signKey: Self.key)
        let book = CloudDeviceTrustRow(deviceId: Self.book, name: "Asad s MacBook Pro", standing: .trusted, code: "EEEE FFFF GGGG HHHH", keyId: "k2", signKey: Self.key)
        // Only in the trust list: the service no longer lists it.
        let old = CloudDeviceTrustRow(deviceId: gone, name: "Office iMac", standing: .trusted, code: "JJJJ KKKK LLLL MMMM", keyId: "k3", signKey: Self.key)
        // Listed by the service under a code-like label only: its trust-list name is used.
        let odd = CloudDeviceTrustRow(deviceId: coded, name: "Studio Mac", standing: .trusted, code: "NNNN PPPP QQQQ RRRR", keyId: "k4", signKey: Self.key)
        var real = device(Self.book, "MacBook Pro", seen: now - 60_000)
        real.displayName = "Asad’s MacBook Pro"
        let snapshot = CloudAccountSnapshot(phase: .signedIn, gate: Self.gate, displayName: "Fixture",
                                            devices: [device(Self.mini, "Mac mini", seen: now), real, device(coded, coded, seen: now - 120_000)],
                                            trust: [mine, book, old, odd], cloudHead: CloudSequence(400), fetched: CloudSequence(400))
        let note = CloudSyncContents.Key(domain: "brain/memory/i01", sourceId: "memory/I01", recordId: "file/notes/a.md", projectId: nil)
        let items: [CloudSyncContents.Item] = [gone, coded, Self.book].enumerated().map { index, id in
            .init(key: .init(domain: note.domain, sourceId: note.sourceId, recordId: "file/notes/n\(index).md", projectId: nil),
                  changes: [.init(deviceId: id, at: now - Int64(index + 1) * 60_000)], standing: .inCloud, seq: CloudSequence(390))
        }
        let model = try #require(BackendCloudContentsBuilder.build(contents: CloudSyncContents(thisDevice: Self.mini, items: items, packs: []),
                                                                   snapshot: snapshot, now: now)).model
        let shown = Set(model.devices.map(\.name) + model.items.map(\.changedBy))
        #expect(shown.contains("Asad’s MacBook Pro"), "the real name when known")
        #expect(!shown.contains("Asad s MacBook Pro"))
        #expect(shown.contains("Office iMac"), "only in the trust list: its trust-list name")
        #expect(shown.contains("Studio Mac"), "a code-like label: the trust-list name")
        for name in shown {
            #expect(!name.isEmpty && Self.leak(name) == nil && name != BackendCloudContentsWords.unknownDevice, "\(name)")
        }
    }

    // 1. Ids and key names.
    @Test func settingKeysBecomeOneCountAndNotesAreNamedByTitle() throws {
        var input = BackendCloudOverviewInput(snapshot: snapshot(coverage: savedCoverage), memory: .init(included: true))
        input.counts = counts
        let overview = try #require(BackendCloudOverviewBuilder.build(input))
        let memory = try #require(overview.rows.first { $0.kind == .memory })
        #expect(memory.notes.contains("5 memory settings belong to this Mac only and stay here."))
        #expect(!memory.notes.contains { $0.contains("Memory setting kept") })
        for text in Self.texts(overview) { #expect(Self.leak(text) == nil, "leaks: \(text)") }

        // Activity and the list: the note's own title, or its file name made readable; the device by its name.
        var names = BackendCloudContentsNames()
        names.notes = ["roles/decker/notes/2026-11-13-cloud-check-dtvjwi.md": "Cloud check results"]
        let titled = try #require(BackendCloudContentsBuilder.build(contents: contents(), snapshot: snapshot(), names: names, counts: counts, now: now)).model
        // Item 5a (14 Nov): the place is the agent's NAME when this Mac knows it, never the folder word ("decker").
        #expect(titled.activity.map(\.text).contains("MacBook Pro sent Cloud check results"))
        #expect(titled.activity.map(\.text).contains("Mac mini received Cloud check results from MacBook Pro"))
        names.agents = ["decker": "Decker"]
        let named = try #require(BackendCloudContentsBuilder.build(contents: contents(), snapshot: snapshot(), names: names, counts: counts, now: now)).model
        #expect(named.activity.map(\.text).contains("MacBook Pro sent Cloud check results for Decker"))
        #expect(named.activity.map(\.text).contains("Mac mini received Cloud check results for Decker from MacBook Pro"))
        let untitled = try #require(BackendCloudContentsBuilder.build(contents: contents(), snapshot: snapshot(), counts: counts, now: now)).model
        #expect(untitled.items(.memory).contains { $0.name == "Cloud check" })
        for text in Self.texts(titled) + Self.texts(untitled) { #expect(Self.leak(text) == nil, "leaks: \(text)") }
        #expect(BackendCloudContentsWords.noteName("notes/" + "a1b2c3d4e5f6a7b8.md", titles: [:]) == nil)
    }

    // 2. One source for every number; both views agree; "on this Mac" only for what is really here.
    @Test func bothViewsGiveTheSameNumbersInThePersonsOwnUnits() throws {
        var input = BackendCloudOverviewInput(snapshot: snapshot(coverage: savedCoverage), memory: .init(included: true))
        input.counts = counts
        let overview = try #require(BackendCloudOverviewBuilder.build(input))
        let window = try #require(BackendCloudContentsBuilder.build(contents: contents(), snapshot: snapshot(), counts: counts, now: now)).model
        let line = "3,523 notes, 39,851 diary entries and 120 topics"
        #expect(overview.rows.first { $0.kind == .memory }?.state == "All saved: " + line)
        #expect(window.kindLines[.memory] == "On this Mac: " + line)
        // No count of sync records anywhere (57,000 records in all).
        for text in Self.texts(overview) + Self.texts(window) { #expect(!text.contains("57") && !text.contains("items saved"), "\(text)") }
        // Every kind carries one number in the window's sidebar (owner, 14 Nov, item 5d): memory shows its notes.
        #expect(window.counts[.memory] == 3_523)
        #expect(window.counts[.agents] == 77)
        #expect(window.counts[.projects] == 4)
        #expect(window.counts[.instructionFiles] == 293)
        // A grouped table shows what is really in this Mac's memory, not the records the sync store holds.
        #expect(window.items(.memory).first { $0.name == "Diary" }?.entries == 39_851)

        // Arrived but not merged: its own plain state in both views, never "On this Mac", and never "level".
        var arriving = BackendCloudPageCounts(here: [.notes: 39, .diary: 293, .topics: 2], arriving: [.diary: 20_480])
        arriving.here[.instructionFiles] = 0
        input.counts = arriving
        let behind = try #require(BackendCloudOverviewBuilder.build(input))
        let sentence = "Arriving: 20,480 diary entries are being added to this Mac."
        #expect(behind.lines.contains(sentence))
        #expect(!behind.lines.contains(BackendCloudOverviewWords.level))
        #expect(behind.standing != .upToDate)
        let window2 = try #require(BackendCloudContentsBuilder.build(contents: contents(), snapshot: snapshot(), counts: arriving, now: now)).model
        #expect(window2.arriving == sentence)
        let diary = try #require(window2.items(.memory).first { $0.name == "Diary" })
        #expect(diary.presence.first == "Arriving on this Mac")
        #expect(diary.entries == 293)
        #expect(diary.note == "20,480 diary entries are being added to this Mac.")
    }

    // 3. Device cards: one per device (this Mac included), level or catching up in the same units, said once.
    @Test func deviceCardsSayLevelOrCatchingUpOnceInTheSameUnits() throws {
        let mid = snapshot(head: 400, fetched: 400, bookPulled: 100)
        let window = try #require(BackendCloudContentsBuilder.build(contents: contents(), snapshot: mid, counts: counts, now: now)).model
        #expect(window.devices.map(\.name) == ["Mac mini", "MacBook Pro"])
        #expect(window.devices[0].isThisMac)
        #expect(window.devices[0].state == "Up to date")
        #expect(window.devices[1].state == "Catching up: 300 changes still to fetch")
        #expect(window.catchingUp == "MacBook Pro (300 changes still to fetch) is still catching up. Everything listed below reaches it by itself.")
        // The rows no longer repeat "waiting on 1 other device".
        for item in window.items { #expect(!BackendCloudContentsWords.presenceLine(item.presence).contains("waiting on"), "\(item.name)") }
        // This Mac's own card is there even when its own trust row is an earlier, stale entry.
        let stale = try #require(BackendCloudContentsBuilder.build(contents: contents(), snapshot: snapshot(ownRowStale: true), counts: counts, now: now)).model
        #expect(stale.devices.filter(\.isThisMac).count == 1)
        #expect(stale.devices.count == 2)
        // This Mac behind by the same measure as Settings → Cloud's line.
        let macBehind = try #require(BackendCloudContentsBuilder.build(contents: contents(), snapshot: snapshot(head: 526, fetched: 400, bookPulled: 526),
                                                                         counts: counts, now: now)).model
        #expect(macBehind.devices[0].state == "Catching up: 126 changes still to fetch")
        var input = BackendCloudOverviewInput(snapshot: snapshot(coverage: savedCoverage, head: 526, fetched: 400), memory: .init(included: true))
        input.counts = counts
        #expect(try #require(BackendCloudOverviewBuilder.build(input)).lines.contains("This Mac is catching up with your Cloud: 126 changes still to fetch."))
        // Level: no line at the top.
        let level = try #require(BackendCloudContentsBuilder.build(contents: contents(), snapshot: snapshot(), counts: counts, now: now)).model
        #expect(level.catchingUp == nil)
        #expect(level.devices[1].state == "Up to date")
    }

    // 4. Saved passwords not set up: an offer, never "needs you", true about today.
    @Test func savedPasswordsNotSetUpIsAnOfferNotATask() throws {
        var page = BackendCloudSecretsPage()
        page.standing = .notSetUp
        var input = BackendCloudOverviewInput(snapshot: snapshot(coverage: savedCoverage), memory: .init(included: true), passwords: page)
        input.counts = counts
        let overview = try #require(BackendCloudOverviewBuilder.build(input))
        #expect(overview.waiting.isEmpty)
        #expect(overview.standing == .upToDate)
        #expect(!overview.title.contains("needs you"))
        // Page-names 2: one state ("Off on this Mac") on the row; the one sentence is said once, in Saved passwords.
        #expect(overview.notices.isEmpty)
        // On by default (owner, 14 Nov): "not set up" is only the moment before this Mac makes the key: no sentence.
        #expect(BackendCloudSecretsWords.advice(page) == nil)
        #expect(BackendCloudOverviewWords.passwordsNotSetUp.contains("optional"))
        // It agrees with the page's own "not saved in this version" list.
        #expect(BackendCloudOverviewWords.passwordsNotSetUp.contains("API keys do not travel yet."))
        #expect(BackendCloudOverviewWords.notSavedInThisVersion.contains("API keys do not travel yet."))
        // Page-names 3: not set up = no summary row at all; the Saved passwords section says it once.
        #expect(overview.rows.first { $0.kind == .passwords } == nil)
        for line in BackendCloudOverviewWords.notSavedInThisVersion { #expect(!line.contains("~/") && !line.contains(".md"), "\(line)") }
    }

    // 5. Preparation finished (n = m): never "Preparing"; Sync now is enabled.
    @Test func preparationThatIsFinishedSaysWhatHappensNext() throws {
        let done = CloudBaselineProgress(total: 56, sent: 56, filesWaiting: 0, waitingUntil: nil, reason: nil, preparing: true)
        let running = CloudBaselineProgress(total: 56, sent: 30, filesWaiting: 0, waitingUntil: nil, reason: nil, preparing: true)
        #expect(!BackendCloudOverviewWords.preparingNow(done))
        #expect(BackendCloudOverviewWords.preparingNow(running))
        #expect(BackendCloudOverviewWords.preparing(done) == "Sending 56 changes")
        #expect(BackendCloudOverviewWords.preparing(running) == "Preparing the first copy: 30 of 56 changes")
        #expect(BackendCloudOverviewWords.syncNowWhilePreparing(done) == BackendCloudOverviewWords.busyHere)
        let behind = snapshot(coverage: [CloudCoverage(sourceId: "memory/I01", inventoryRow: "I01", complete: false, items: 0, bytes: 0, blockedReasons: [])],
                              baseline: done, head: 526, fetched: 400)
        var input = BackendCloudOverviewInput(snapshot: behind, memory: .init(included: true))
        input.counts = counts
        let overview = try #require(BackendCloudOverviewBuilder.build(input))
        #expect(overview.title == "Sending 56 changes")
        #expect(overview.lines.contains("This Mac is catching up with your Cloud: 126 changes still to fetch."))
        for text in Self.texts(overview) { #expect(!text.contains("Preparing"), "\(text)") }
        let window = try #require(BackendCloudContentsBuilder.build(contents: contents(), snapshot: behind, counts: counts, now: now)).model
        #expect(window.devices[0].state == "Sending 56 changes")
    }

    // 6. The sweep: plain notes from the store and internal words never reach the page.
    @Test func storeNotesAreMadePlain() {
        let notes = BackendCloudPageWords.plainNotes(
            DeckMemoryCloudSchema.unknownSettingNotes(Self.settingKeys)
            + DeckMemoryCloudSchema.fileExclusions(hidden: 3, links: 1, appHelp: 4)
            + ["Local database backups: kept on this Mac only.", "2 memory records could not be read for Cloud and are not saved there."])
        #expect(notes == ["5 memory settings belong to this Mac only and stay here.", "3 hidden files and folders stay on this Mac.",
                          "1 linked file or folder stays on this Mac.", "Local database backups: kept on this Mac only.",
                          "2 memory entries could not be read for Cloud and are not saved there."])
        for line in notes { #expect(Self.leak(line) == nil, "\(line)") }
        #expect(!BackendCloudPageWords.isPlain("Waiting for the outbox to drain"))
        #expect(!BackendCloudPageWords.isPlain("Memory setting kept on this Mac: refresh.last"))
        #expect(BackendCloudPageWords.isPlain("This Mac has everything your Cloud holds."))
    }
}
