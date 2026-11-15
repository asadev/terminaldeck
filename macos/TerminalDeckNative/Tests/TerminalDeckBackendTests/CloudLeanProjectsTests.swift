import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Lane A2 lean item 2: the list of projects arrives on a second Mac, and a folder never does.
/// Real `BackendPROJRegistry` files in scratch folders; no network, no real app data.
@Suite("Cloud lean — projects arrive on a second Mac without their folders")
struct CloudLeanProjectsTests {
    struct Side: Sendable {
        let mac: CloudLeanFixtureMac
        let registry: BackendPROJRegistry
        let owner: BackendCloudLeanProjects
        let adapter: CloudBrainRecordAdapter
        let notices: CloudLeanFixture.Counter
        let displays: CloudLeanFixture.Counter
        let memory: CloudLeanFixture.Counter
    }
    static func side(_ device: String, clock: CloudLeanFixture.Clock, subject: String = CloudLeanFixture.subjectX, root: URL? = nil) throws -> Side {
        let mac = try CloudLeanFixture.mac(device, clock: clock, subject: subject, root: root)
        let notices = CloudLeanFixture.Counter(), displays = CloudLeanFixture.Counter(), memory = CloudLeanFixture.Counter()
        let registry = BackendPROJRegistry(fileURL: mac.root.appendingPathComponent("projects.registry.json"), changed: { _ in notices.bump() })
        let owner = BackendCloudLeanProjects(registry: registry, display: { displays.bump() }, memory: { memory.bump() })
        let adapter = try owner.adapter(store: mac.store, account: mac.account, origins: mac.origins)
        return Side(mac: mac, registry: registry, owner: owner, adapter: adapter, notices: notices, displays: displays, memory: memory)
    }
    private func project(_ side: Side, _ id: String) async throws -> PROJProject? {
        let projects = try await side.registry.projects()
        return projects.first { $0.id == id }
    }

    @Test func aProjectArrivesWithItsNameAndNoFolderAndNothingElseIsCreated() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try Self.side(CloudLeanFixture.deviceA, clock: clock), b = try Self.side(CloudLeanFixture.deviceB, clock: clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await a.registry.save(PROJProject(id: "deck", name: "Deck", folders: ["/Users/person-a/Code/deck"], icon: "terminal", colour: "teal",
            logo: "deck-logo.png", lead: "agent:lead-a", leadName: "Lead A"))

        let startedA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        let sent = startedA.sent
        #expect(sent.count == 1)
        let travelled = CloudLeanFixture.text(sent)
        #expect(!travelled.contains("person-a"), "A folder path is never in what travels")
        #expect(!travelled.contains("folders") && !travelled.contains("roots"), "No folder field travels in this version")
        #expect(!travelled.contains("deck-logo"), "A logo's file name stays on its Mac")

        let startedB = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        let noticesBefore = b.notices.count, memoryBefore = b.memory.count
        try await CloudLeanFixture.deliver(sent, from: a.mac.device, to: b.adapter)
        let arrived = try await project(b, "deck")
        #expect(arrived?.name == "Deck")
        #expect(arrived?.icon == "terminal")
        #expect(arrived?.colour == "teal")
        #expect(arrived?.folders == [], "It arrives with no folder: the person chooses one on this Mac")
        #expect(arrived?.lead == "", "A lead chosen on another device is not applied here")
        let needing = try await b.owner.needingFolder()
        #expect(needing == [BackendCloudLeanProjects.NeedsFolder(id: "deck", name: "Deck")])
        let listing = try await b.adapter.listing()
        let waitingFields = listing.waiting.map { $0.record + "/" + $0.field }
        #expect(waitingFields.contains("project:deck/lead"), "The lead is listed as waiting on this Mac: \(waitingFields)")
        #expect(b.notices.count == noticesBefore, "An import raises no change notice")
        #expect(b.displays.count == 1, "Screens refresh once, display only")
        // G (13 Nov): the project's record alone lets its memory follow; memory is asked once to place what waited.
        #expect(b.memory.count == memoryBefore + 1, "Memory that waited for the project is placed as soon as it arrives")

        // An import is not an edit: B sends nothing back, and A's folder is still A's.
        let echo = try await CloudLeanFixture.sync(startedB.activation, on: b.mac)
        #expect(echo.isEmpty)
        let onA = try await project(a, "deck")
        #expect(onA?.folders == ["/Users/person-a/Code/deck"])
    }

    @Test func choosingAFolderIsStoredOnThisMacOnlyAndTellsMemory() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try Self.side(CloudLeanFixture.deviceA, clock: clock), b = try Self.side(CloudLeanFixture.deviceB, clock: clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await a.registry.save(PROJProject(id: "deck", name: "Deck", folders: ["/Users/person-a/Code/deck"], colour: "teal"))
        let startedA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        let startedB = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: b.adapter)

        let resolver = b.owner.memoryResolver()
        #expect(resolver("deck", "other-store") == "deck", "G: memory follows as soon as the project's record is on this Mac; no folder needed")
        let askedBefore = b.memory.count
        let chosen = b.mac.root.appendingPathComponent("my-deck-folder")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        try await b.owner.chooseFolder(projectID: "deck", folder: chosen.path)
        let onB = try await project(b, "deck")
        #expect(onB?.folders == [PROJProjects.normalize(chosen.path)])
        #expect(resolver("deck", "other-store") == "deck", "Still the same project id once a folder is chosen")
        #expect(resolver("other-project", "other-store") == nil)
        #expect(b.memory.count == askedBefore, "Choosing a folder later asks nothing more of memory")
        let needing = try await b.owner.needingFolder()
        #expect(needing.isEmpty)

        // Choosing a folder on B makes no version: nothing about folders goes to the Cloud.
        let fromB = try await CloudLeanFixture.sync(startedB.activation, on: b.mac)
        #expect(fromB.isEmpty, "Adding a folder on one Mac sends nothing")
        // A adds a second folder: nothing travels, and B's folder list is exactly what B chose.
        let foundA = try await project(a, "deck")
        var onA = try #require(foundA)
        onA.folders.append("/Users/person-a/Code/deck-two")
        _ = try await a.registry.save(onA)
        let fromA = try await CloudLeanFixture.sync(startedA.activation, on: a.mac)
        #expect(fromA.isEmpty)
        let stillB = try await project(b, "deck")
        #expect(stillB?.folders == [PROJProjects.normalize(chosen.path)], "Adding a folder on one Mac never changes another Mac's folders")

        // A missing folder, or the built-in Independent project, is refused.
        await #expect(throws: NativeRPCError.self) { try await b.owner.chooseFolder(projectID: "deck", folder: "/nowhere/at/all") }
        await #expect(throws: NativeRPCError.self) { try await b.owner.chooseFolder(projectID: PROJProjects.independentID, folder: chosen.path) }
    }

    @Test func aRenameArrivesAndAnUnintendedMissingRowSendsNoRemoval() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try Self.side(CloudLeanFixture.deviceA, clock: clock), b = try Self.side(CloudLeanFixture.deviceB, clock: clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await a.registry.save(PROJProject(id: "notes", name: "Notes", colour: "blue"))
        let startedA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        _ = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: b.adapter)

        _ = try await a.registry.save(PROJProject(id: "notes", name: "Field notes", colour: "blue"))
        let rename = try await CloudLeanFixture.sync(startedA.activation, on: a.mac)
        #expect(rename.count == 1)
        try await CloudLeanFixture.deliver(rename, from: a.mac.device, to: b.adapter)
        let renamed = try await project(b, "notes")
        #expect(renamed?.name == "Field notes")
        let listing = try await b.adapter.listing()
        let listed = listing.changes.contains { $0.record == "project:notes" && $0.field == "name" && $0.from == "Notes" && $0.to == "Field notes" && $0.device == a.mac.device }
        #expect(listed, "The rename is listed with the device it came from")

        // A row disappearing outside the delete owner is not an intended travelling removal.
        // Review fix F (de297bdca, 15 Nov): the app's Remove and project_registry.remove_empty (`removeEmpty`) now ARE the
        // delete owner (Everywhere, Bin 30 days), so the unintended case is the registry entry vanishing with no intent:
        // the entry-only writer, which records none.
        try await a.registry.cloudDeleteEntryOnly("notes")
        let removal = try await CloudLeanFixture.sync(startedA.activation, on: a.mac)
        #expect(removal.isEmpty)
        try await CloudLeanFixture.deliver(removal, from: a.mac.device, to: b.adapter)
        let kept = try await project(b, "notes")
        #expect(kept?.name == "Field notes", "A project removed on another device stays on this one")
    }

    /// Project folders (14 Nov): one odd name never makes a project disappear. It arrives under the plain form of its
    /// name (the line break made a space), the original is held and listed, and nothing is sent back.
    @Test func aProjectWhoseNameIsNotOnePlainLineArrivesUnderItsPlainNameAndIsListed() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try Self.side(CloudLeanFixture.deviceA, clock: clock), b = try Self.side(CloudLeanFixture.deviceB, clock: clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await a.registry.save(PROJProject(id: "odd", name: "Looks fine\nSecond line pretending to be something else", colour: "blue"))
        _ = try await a.registry.save(PROJProject(id: "fine", name: "Fine", colour: "green"))
        let startedA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        let startedB = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: b.adapter)

        let odd = try await project(b, "odd"), fine = try await project(b, "fine")
        #expect(odd?.name == "Looks fine Second line pretending to be something else", "It is added, under one plain line")
        #expect(fine?.name == "Fine", "The record beside it arrives: nothing is parked for it")
        let listing = try await b.adapter.listing()
        let waiting = listing.waiting.map { $0.record + "/" + $0.field }
        #expect(waiting == ["project:odd/name"], "Its original name is listed as held, with the reason")
        let reason = listing.waiting.first?.reason ?? ""
        #expect(reason.contains("one plain line"))
        #expect(try await CloudLeanFixture.sync(startedB.activation, on: b.mac).isEmpty, "The plain name is never sent back")

        // Renamed to one plain line on A: the next version is taken (it was never stuck behind the first).
        _ = try await a.registry.save(PROJProject(id: "odd", name: "Plain now", colour: "blue"))
        let fixed = try await CloudLeanFixture.sync(startedA.activation, on: a.mac)
        try await CloudLeanFixture.deliver(fixed, from: a.mac.device, to: b.adapter)
        let added = try await project(b, "odd")
        #expect(added?.name == "Plain now")
        let after = try await b.adapter.listing()
        #expect(after.waiting.isEmpty)
    }

    @Test func aDamagedProjectListSendsNothingAndCountsNothingAsRemoved() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try Self.side(CloudLeanFixture.deviceA, clock: clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root) }
        _ = try await a.registry.save(PROJProject(id: "deck", name: "Deck", colour: "teal"))
        let started = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        #expect(started.sent.count == 1)

        // The same Mac after a restart with a registry file that no longer reads: a new registry over broken bytes.
        try Data("{ not a project list".utf8).write(to: a.mac.root.appendingPathComponent("projects.registry.json"))
        let broken = BackendPROJRegistry(fileURL: a.mac.root.appendingPathComponent("projects.registry.json"))
        let owner = BackendCloudLeanProjects(registry: broken)
        let adapter = try owner.adapter(store: a.mac.store, account: a.mac.account, origins: a.mac.origins)
        let changed = try await adapter.captureLocal()
        #expect(!changed)
        let unsent = try a.mac.store.ownUnhanded(domain: "projects", limit: 16)
        #expect(unsent.isEmpty, "A list that cannot be read is never taken for 'every project was removed'")
        let inventory = try await adapter.sourceInventory()
        #expect(inventory.first?.complete == false)
    }
}
