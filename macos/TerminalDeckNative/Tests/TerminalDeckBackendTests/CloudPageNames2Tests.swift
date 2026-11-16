import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Page-names 2 (owner, 13 Nov, second check of his two real Macs): "needs you" counts only what blocks his work and
/// only he can do; "All saved" only when nothing of that part is going up or still arriving; one card per signed-in
/// device including this Mac; titles cut between words; one state for saved passwords. Built from the shapes the real
/// pages showed (four projects without a folder, 293 instruction files, 120 held changes, a failed saved-passwords
/// check, memory arriving beside memory already here, two devices of which one is this Mac).
@Suite("Cloud pages, round 2 — only real tasks, true totals, every device")
struct CloudPageNames2Tests {
    static let gate = CloudGate(features: ["cloud"], storageEntitled: true)
    static let mini = "33333333-3333-4333-8333-333333333333"
    static let book = "44444444-4444-4444-8444-444444444444"
    static let key = CloudPublicJWK(kty: "EC", crv: "P-256", x: "x", y: "y")
    let now: Int64 = 1_794_000_000_000

    static func texts(_ overview: BackendCloudOverview) -> [String] {
        [overview.title] + overview.lines + overview.waiting.map(\.text) + overview.notices.map(\.text)
            + overview.rows.flatMap { [$0.title, $0.state] + $0.notes }
            + (overview.later.map { [$0.summary] + $0.items.map(\.text) } ?? [])
    }
    func device(_ id: String, _ label: String, seen: Int64, pulled: UInt64? = nil) -> CloudDevice {
        var made = CloudDevice(deviceId: id, label: label, platform: .macos, appVersion: "fixture", status: .active, secretsApproved: false,
                               lastSeenAt: seen, signPublicJwk: Self.key, wrapPublicJwk: Self.key, registeredAt: now - 86_400_000)
        made.lastPulledSeq = pulled.map { CloudSequence($0) }
        return made
    }
    /// Memory, projects and agents wholly in your Cloud; boot files only waiting for a folder (the MacBook's shape).
    var macBookCoverage: [CloudCoverage] {
        [("I01", 1_892), ("I02", 6_658), ("I06", 33), ("I10", 2), ("I11", 1)].map { row, items in
            CloudCoverage(sourceId: "memory/" + row, inventoryRow: row, complete: true, items: items, bytes: 10, blockedReasons: [])
        } + [CloudCoverage(sourceId: "boot/not-on-this-mac", inventoryRow: CloudBootFilesFormat.inventoryRow, complete: false, items: 293, bytes: 10,
                           blockedReasons: ["293 boot files wait for a folder on this Mac."])]
    }
    /// The MacBook: level with the Cloud (407 of 407), trust rows for both Macs, the device list with both.
    func macBook(coverage: [CloudCoverage], head: UInt64 = 407, fetched: UInt64 = 407, miniPulled: UInt64? = 404,
                 thisRowId: String? = nil, trustRows: Bool = true) -> CloudAccountSnapshot {
        let mine = CloudDeviceTrustRow(deviceId: thisRowId ?? Self.book, name: "asads-macbook-pro-21.local", standing: .thisMac, code: "AAAA BBBB CCCC DDDD",
                                       keyId: "k1", signKey: Self.key)
        let other = CloudDeviceTrustRow(deviceId: Self.mini, name: "imatch-mac-mini.local", standing: .trusted, code: "EEEE FFFF GGGG HHHH", keyId: "k2", signKey: Self.key)
        return CloudAccountSnapshot(phase: .signedIn, gate: Self.gate, displayName: "Fixture",
                                    devices: [device(Self.mini, "imatch-mac-mini.local", seen: now - 60_000, pulled: miniPulled),
                                              device(Self.book, "asads-macbook-pro-21.local", seen: now, pulled: fetched)],
                                    coverage: coverage, trust: trustRows ? [mine, other] : [],
                                    cloudHead: CloudSequence(head), fetched: CloudSequence(fetched))
    }
    let fourProjects: [BackendCloudOverview.Waiting] = [("crm", "CRM"), ("imatch", "iMatch"), ("ipresent", "iPresent"), ("terminal-deck", "Deck Dev")].map {
        .init(id: "project:" + $0.0, text: $0.1, action: .chooseFolder(projectId: $0.0))
    }
    /// What the MacBook's memory and lists really held, with what still arrives from the Cloud.
    var macBookCounts: BackendCloudPageCounts {
        BackendCloudPageCounts(here: [.notes: 1_892, .diary: 6_658, .topics: 33, .settings: 28, .projects: 4, .agents: 1, .instructionFiles: 0],
                               arriving: [.notes: 3_228, .diary: 33_255, .agents: 77], waitingForFolder: 293)
    }
    func macBookInput(held: Int, automaticTrust: Bool, passwords: BackendCloudSecretsPage? = nil) -> BackendCloudOverviewInput {
        var input = BackendCloudOverviewInput(snapshot: macBook(coverage: macBookCoverage), memory: .init(included: true),
                                              projects: .init(later: fourProjects, heldChanges: held),
                                              bootFiles: .init(filesForFolders: 293), passwords: passwords)
        input.automaticTrust = automaticTrust
        input.counts = macBookCounts
        return input
    }
    func contents(thisDevice: String) -> CloudSyncContents {
        let note = CloudSyncContents.Key(domain: "brain/memory/i01", sourceId: "memory/I01", recordId: "file/notes/2026-11-13-cloud-check-dtvjwi.md", projectId: nil)
        return CloudSyncContents(thisDevice: thisDevice, items: [.init(key: note, changes: [.init(deviceId: Self.mini, at: now - 300_000)], standing: .inCloud,
                                                                       seq: CloudSequence(390))],
                                 packs: [.init(deviceId: Self.mini, at: now - 300_000, arrivedAt: now - 290_000, keys: [note], count: ["brain/memory/i01": 1])])
    }

    // Z1. "8 things need you" on the MacBook: nothing of that is a task.
    @Test func onlyRealTasksNeedYou() throws {
        var unchecked = BackendCloudSecretsPage()
        unchecked.standing = .unknown
        let overview = try #require(BackendCloudOverviewBuilder.build(macBookInput(held: 120, automaticTrust: true, passwords: unchecked)))
        #expect(overview.waiting.isEmpty)
        #expect(overview.standing != .needsYou)
        #expect(!overview.title.contains("need"))
        // Project folders (14 Nov): folders are made by themselves; the page says nothing about projects without one.
        #expect(overview.later == nil)
        #expect(!Self.texts(overview).contains { $0.contains("no folder on this Mac") || $0.contains("Choose a folder") || $0.contains("choose a folder") })
        #expect(!Self.texts(overview).contains { $0.contains("Choose one") || $0.contains("for a folder on this Mac") })
        // A failed saved-passwords check: one calm line with Check again, not counted.
        #expect(overview.notices.map(\.text) == [BackendCloudOverviewWords.passwordsNotChecked])
        #expect(overview.notices.map(\.action) == [.checkAgain])
        // Held changes: nothing under automatic trust, nothing when none is held under either setting.
        #expect(!Self.texts(overview).contains { $0.contains("held") || $0.contains("your OK") })
        let none = try #require(BackendCloudOverviewBuilder.build(macBookInput(held: 0, automaticTrust: false)))
        #expect(!Self.texts(none).contains { $0.contains("held") || $0.contains("your OK") })
        #expect(none.waiting.isEmpty)
        // Under the stricter setting: one plain line, and it is the one thing that needs him.
        let strict = try #require(BackendCloudOverviewBuilder.build(macBookInput(held: 120, automaticTrust: false)))
        #expect(strict.waiting.map(\.text) == ["120 changes to your projects and agents wait for your OK on this Mac."])
        #expect(strict.title == BackendCloudOverviewWords.needsYou(1))
    }

    // Z2. "All saved" only when nothing of that part is going up or still arriving; projects and agents of the account.
    @Test func allSavedIsTrueOrNotSaid() throws {
        let overview = try #require(BackendCloudOverviewBuilder.build(macBookInput(held: 0, automaticTrust: true)))
        let memory = try #require(overview.rows.first { $0.kind == .memory })
        #expect(memory.state == "Adding 3,228 notes and 33,255 diary entries from your Cloud")
        #expect(!memory.settled)
        let projects = try #require(overview.rows.first { $0.kind == .projects })
        #expect(projects.state == "Adding 77 agents from your Cloud")
        let boot = try #require(overview.rows.first { $0.kind == .bootFiles })
        #expect(boot.state == "Adding 293 instruction files from your Cloud", "Project folders: nothing about choosing a folder")
        for row in overview.rows { #expect(!row.state.contains("All saved"), "\(row.title): \(row.state)") }
        #expect(!overview.lines.contains(BackendCloudOverviewWords.notAllSaved))
        #expect(!Self.texts(overview).contains("Not complete"))
        // The window counts what he would count: 4 projects and 78 agents in his account.
        let window = try #require(BackendCloudContentsBuilder.build(contents: contents(thisDevice: Self.book), snapshot: macBook(coverage: macBookCoverage),
                                                                    counts: macBookCounts, now: now)).model
        #expect(window.counts[.projects] == 4)
        #expect(window.counts[.agents] == 78)
        // Once nothing arrives any more, the same rows say "All saved" with the same numbers.
        var settled = macBookCounts
        settled.arriving = [:]
        settled.here[.agents] = 78
        var input = macBookInput(held: 0, automaticTrust: true)
        input.counts = settled
        let done = try #require(BackendCloudOverviewBuilder.build(input))
        #expect(done.rows.first { $0.kind == .projects }?.state == "All saved: 4 projects and 78 agents")
        #expect(done.rows.first { $0.kind == .memory }?.state == "All saved: 1,892 notes, 6,658 diary entries and 33 topics")
        // Topics: never fewer than the memory lists without a word why (Mac mini: 61 here, 3 marked missing).
        settled.here[.topics] = 61
        settled.missing = [.topics: 3]
        input.counts = settled
        let mini = try #require(BackendCloudOverviewBuilder.build(input))
        let notes = try #require(mini.rows.first { $0.kind == .memory }).notes
        #expect(notes.contains("3 topics are also listed in your memory, but their files are gone from this Mac, so they are not counted."))
    }

    // Z3. One card per signed-in device, this Mac included; numbers only when current; this Mac never "catching up" when level.
    @Test func everyDeviceHasItsCardAndThisMacIsNeverWronglyBehind() throws {
        for snapshot in [macBook(coverage: macBookCoverage), macBook(coverage: macBookCoverage, trustRows: false),
                         macBook(coverage: macBookCoverage, thisRowId: "55555555-5555-4555-8555-555555555555")] {
            let window = try #require(BackendCloudContentsBuilder.build(contents: contents(thisDevice: Self.book), snapshot: snapshot,
                                                                        counts: macBookCounts, positionMovedAt: [:], now: now)).model
            #expect(window.devices.count == 2)
            #expect(window.devices.filter(\.isThisMac).map(\.name) == ["asads-macbook-pro-21.local"])
            #expect(window.devices.filter { !$0.isThisMac }.map(\.name) == ["imatch-mac-mini.local"])
            // Level with the Cloud while memory is still being added here: not "catching up".
            let this = try #require(window.devices.first { $0.isThisMac })
            #expect(this.state == BackendCloudPageWords.addingHere)
            #expect(!(window.catchingUp ?? "").contains("This Mac"))
            // The Mac mini's position was never seen to move: "Catching up", with no number.
            #expect(window.devices.first { !$0.isThisMac }?.state == "Catching up")
        }
        // Seen moving within the last minutes: its number against the Cloud's head now.
        let fresh = try #require(BackendCloudContentsBuilder.build(contents: contents(thisDevice: Self.book), snapshot: macBook(coverage: macBookCoverage),
                                                                   counts: macBookCounts, positionMovedAt: [Self.mini: now - 30_000], now: now)).model
        #expect(fresh.devices.first { !$0.isThisMac }?.state == "Catching up: 3 changes still to fetch")
        #expect(fresh.catchingUp == "imatch-mac-mini.local (3 changes still to fetch) is still catching up. Everything listed below reaches it by itself.")
        // The window places every card: no lazy grid that can leave one out.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("Sources/TerminalDeckNative/NativeCloudContents.swift"), encoding: .utf8)
        #expect(!view.contains("LazyVGrid("))
        #expect(view.contains("NativeCloudCardFlow("))
    }

    // Z4. Titles: cut between words and ending with "…"; a file-style title made readable.
    @Test func titlesAreCutBetweenWords() {
        let sentence = "Product goal maximum possibilities maximum convenience and the least complication"
        let sixty = String(sentence.prefix(60))
        #expect(sixty.count == 60)
        let path = "notes/2026-11-13-product-goal-dtvjwi.md"
        let shown = BackendCloudContentsWords.noteName(path, titles: [path: sixty]) ?? ""
        #expect(shown.hasSuffix("…"))
        #expect(shown.count <= 60)
        let words = Set(sentence.split(separator: " ").map(String.init))
        for word in shown.dropLast().split(separator: " ") { #expect(words.contains(String(word)), "cut mid-word: \(shown)") }
        // A long title of its own: cut at a word too.
        let long = BackendCloudContentsWords.shortTitle(sentence + " for every person who uses the app every day")
        #expect(long.hasSuffix("…") && long.count <= 60)
        for word in long.dropLast().split(separator: " ") { #expect(sentence.contains(String(word)) || "for every person who uses the app every day".contains(String(word))) }
        // The app cut the file name at 48 characters: the piece of a word is left out.
        #expect(BackendCloudContentsWords.noteName("notes/2026-11-13-product-goal-maximum-possibilities-maximum-conve-abc123.md", titles: [:])
                == "Product goal maximum possibilities maximum…")
        // A title that is itself a file name.
        let retired = "team/2026-11-02-app-domain-retired.md"
        #expect(BackendCloudContentsWords.noteName(retired, titles: [retired: "2026-11-02-app-domain-retired"]) == "App domain retired")
        #expect(BackendCloudContentsWords.noteName(retired, titles: [:]) == "App domain retired")
        // A short title is left as it is.
        #expect(BackendCloudContentsWords.noteName(path, titles: [path: "Cloud check results"]) == "Cloud check results")
    }

    // Z5. Saved passwords: one state, one sentence, the same in both places.
    @Test func savedPasswordsSayOneThing() throws {
        var off = BackendCloudSecretsPage()
        off.standing = .notSetUp
        let page = try #require(BackendCloudOverviewBuilder.build(macBookInput(held: 0, automaticTrust: true, passwords: off)))
        // Page-names 3: no summary row while off; the state word stays for the Saved passwords section's full view.
        #expect(page.rows.first { $0.kind == .passwords } == nil)
        #expect(BackendCloudSecretsWords.state(off) == BackendCloudSecretsWords.turningOn)
        #expect(!Self.texts(page).contains("Not set up yet"))
        // The one sentence is said once: in Saved passwords, not again in the summary.
        #expect(BackendCloudSecretsWords.advice(off) == nil)
        #expect(!Self.texts(page).contains(BackendCloudOverviewWords.passwordsNotSetUp))
        var unknown = BackendCloudSecretsPage()
        unknown.standing = .unknown
        let failed = try #require(BackendCloudOverviewBuilder.build(macBookInput(held: 0, automaticTrust: true, passwords: unknown)))
        #expect(failed.rows.first { $0.kind == .passwords }?.state == BackendCloudSecretsWords.state(unknown))
        #expect(BackendCloudSecretsWords.state(unknown) == "Could not be checked on this Mac just now")
        #expect(failed.waiting.isEmpty)
    }
}
