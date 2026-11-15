import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Lane A2 lean item 5: first sign-in on a second Mac that already has projects or agents (rule J as built).
/// The Cloud's record wins, this Mac's differing values are kept as other versions; the same id is the same record;
/// the same name under another id is never merged.
@Suite("Cloud lean — a second Mac that already has projects or agents joins: the Cloud wins, this Mac's values are kept")
struct CloudLeanJoinTests {
    private func project(_ side: CloudLeanProjectsTests.Side, _ id: String) async throws -> PROJProject? {
        let projects = try await side.registry.projects()
        return projects.first { $0.id == id }
    }
    private func baselines(_ operations: [CloudOperation]) -> [Bool] { operations.map { $0.payload.raw["baseline"].bool == true } }

    @Test func aProjectWithTheSameIdIsTheSameProjectAndTheSameNameUnderAnotherIdStaysSeparate() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try CloudLeanProjectsTests.side(CloudLeanFixture.deviceA, clock: clock), b = try CloudLeanProjectsTests.side(CloudLeanFixture.deviceB, clock: clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        // Mac A is in the Cloud first.
        _ = try await a.registry.save(PROJProject(id: "deck", name: "Deck", colour: "teal"))
        let startedA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        // Mac B already has a project with the same id (other name and colour, its own folder) and one with the same
        // NAME under another id.
        _ = try await b.registry.save(PROJProject(id: "deck", name: "Deck (old laptop)", folders: ["/Users/person-b/deck"], colour: "pink"))
        _ = try await b.registry.save(PROJProject(id: "deck-b", name: "Deck", colour: "blue"))
        let startedB = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        #expect(startedB.sent.count == 2)
        #expect(baselines(startedB.sent) == [true, true], "A joining Mac's own copies go up marked as its baseline, never as new edits")

        try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: b.adapter)
        try await CloudLeanFixture.deliver(startedB.sent, from: b.mac.device, to: a.adapter)

        // Same id: one project. The Cloud's values are shown on both; B's folder is still B's.
        let deckB = try await project(b, "deck"), deckA = try await project(a, "deck")
        #expect(deckB?.name == "Deck" && deckB?.colour == "teal", "The Cloud's record wins on the joining Mac")
        #expect(deckB?.folders == ["/Users/person-b/deck"])
        #expect(deckA?.name == "Deck" && deckA?.colour == "teal", "and the established Mac is unchanged")
        // B's differing values are kept as other versions, readable on B, counted on A.
        let listingB = try await b.adapter.listing(), listingA = try await a.adapter.listing()
        let keptB = listingB.kept.filter { $0.record == "project:deck" }
        let previews = Set(keptB.compactMap { $0.preview })
        #expect(previews == ["Deck (old laptop)", "pink"], "\(keptB)")
        #expect(listingA.keptCount == 2)
        let shownOnA = listingA.kept.compactMap { $0.preview }
        #expect(shownOnA.isEmpty, "Another device's kept values are counted on this Mac, not shown")

        // Same name, another id: NOT merged. Both Macs list two projects called "Deck".
        let otherB = try await project(b, "deck-b"), otherA = try await project(a, "deck-b")
        #expect(otherB?.name == "Deck" && otherB?.colour == "blue")
        #expect(otherA?.name == "Deck" && otherA?.folders == [], "It arrives on A as its own project, with no folder")
        let allA = try await a.registry.projects()
        let namedDeck = allA.filter { $0.name == "Deck" }.map { $0.id }.sorted()
        #expect(namedDeck == ["deck", "deck-b"])

        // Settled: nothing more is sent by either Mac.
        let moreA = try await CloudLeanFixture.sync(startedA.activation, on: a.mac), moreB = try await CloudLeanFixture.sync(startedB.activation, on: b.mac)
        #expect(moreA.isEmpty && moreB.isEmpty)
    }

    @Test func anAgentThisMacAlreadyHasTakesTheCloudsTextAndKeepsItsOwnAsAnOtherVersion() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await CloudLeanAgentsTests.side(CloudLeanFixture.deviceA, clock: clock), b = try await CloudLeanAgentsTests.side(CloudLeanFixture.deviceB, clock: clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await a.config.saveAgent(CloudLeanAgentsTests.agent("reviewer", "Reviewer", [("role", .string("Reviews every change")), ("instructions", .string("The Cloud's text."))]))
        _ = try await b.config.saveAgent(CloudLeanAgentsTests.agent("reviewer", "Reviewer", [("role", .string("An older role")), ("instructions", .string("This Mac's older text.")),
            ("permissionMode", .string("acceptEdits"))]))
        let startedA = try await CloudLeanFixture.start([a.adapter], on: a.mac)

        // The Cloud's records reach B during its first pull, before B has cut anything of its own.
        try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: b.adapter)
        let onB = try await b.config.agent("reviewer")
        #expect(onB?["role"].string == "Reviews every change")
        #expect(onB?["instructions"].string == "The Cloud's text.")
        #expect(onB?["permissionMode"].string == "acceptEdits", "This Mac's own permission mode is never changed from another device")
        let listingB = try await b.adapter.listing()
        let previews = Set(listingB.kept.compactMap { $0.preview })
        #expect(previews.contains("An older role") && previews.contains("This Mac's older text."), "This Mac's differing values are kept: \(previews)")
        let waiting = listingB.waiting.map { $0.record + "/" + $0.field }
        #expect(waiting.contains("agent:reviewer/permissionMode"))

        // B's own copies then go up as its baseline, and change nothing on A.
        let startedB = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        #expect(!startedB.sent.isEmpty)
        #expect(baselines(startedB.sent).allSatisfy { $0 })
        try await CloudLeanFixture.deliver(startedB.sent, from: b.mac.device, to: a.adapter)
        let onA = try await a.config.agent("reviewer")
        #expect(onA?["role"].string == "Reviews every change")
        #expect(onA?["instructions"].string == "The Cloud's text.")
        #expect(onA?["permissionMode"].string == nil)
    }

    @Test func aLostBookkeepingDatabaseJoinsAgainAndIsNeverTakenForEverythingNew() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try CloudLeanProjectsTests.side(CloudLeanFixture.deviceA, clock: clock), b = try CloudLeanProjectsTests.side(CloudLeanFixture.deviceB, clock: clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await a.registry.save(PROJProject(id: "deck", name: "Deck", colour: "teal"))
        let startedA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        let startedB = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: b.adapter)
        // B renames it; A takes the rename. Then A's bookkeeping database is lost (the projects themselves are not).
        _ = try await b.registry.save(PROJProject(id: "deck", name: "Deck renamed on B", colour: "teal"))
        let rename = try await CloudLeanFixture.sync(startedB.activation, on: b.mac)
        try await CloudLeanFixture.deliver(rename, from: b.mac.device, to: a.adapter)
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: a.mac.store.file.path + suffix) }

        // The same Mac again: a new (empty) database beside the finished setup's cut.
        let again = try CloudLeanProjectsTests.side(CloudLeanFixture.deviceA, clock: clock, root: a.mac.root)
        #expect(again.mac.store.opening == .fresh)
        let restarted = try await CloudLeanFixture.start([again.adapter], on: again.mac)
        #expect(restarted.sent.count == 1)
        #expect(baselines(restarted.sent) == [true], "A lost database is a join: this Mac's records go up as a baseline, not as new edits")
        try await CloudLeanFixture.deliver(restarted.sent, from: again.mac.device, to: b.adapter)
        let onB = try await project(b, "deck")
        #expect(onB?.name == "Deck renamed on B", "The other Mac keeps what the Cloud holds")
        let listingB = try await b.adapter.listing()
        #expect(listingB.keptCount == 0, "An identical copy adds no other version")
    }
}
