import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Lane A2 lean item 6: account rules. Records remember the account they came from; nothing of account X is ever
/// sent into account Y; sign-out deletes nothing and stops every capture. Fixture subject hashes, scratch folders.
@Suite("Cloud lean — records remember their Cloud account; sign-out stops every capture and deletes nothing")
struct CloudLeanAccountTests {
    private func project(_ side: CloudLeanProjectsTests.Side, _ id: String) async throws -> PROJProject? {
        let projects = try await side.registry.projects()
        return projects.first { $0.id == id }
    }

    @Test func nothingOfOneAccountIsEverSentIntoOrMergedWithAnother() async throws {
        let clock = CloudLeanFixture.Clock()
        let x = try CloudLeanProjectsTests.side(CloudLeanFixture.deviceA, clock: clock, subject: CloudLeanFixture.subjectX)
        defer { try? FileManager.default.removeItem(at: x.mac.root) }
        _ = try await x.registry.save(PROJProject(id: "deck", name: "Deck of account X", colour: "teal"))
        let startedX = try await CloudLeanFixture.start([x.adapter], on: x.mac)
        #expect(startedX.sent.count == 1)
        await startedX.activation.stop()                              // signed out of X

        // The same Mac signs in to account Y: X's record is edited here, and a new project is made.
        let y = try CloudLeanProjectsTests.side(CloudLeanFixture.deviceA, clock: clock, subject: CloudLeanFixture.subjectY, root: x.mac.root)
        _ = try await y.registry.save(PROJProject(id: "deck", name: "Deck edited while in Y", colour: "teal"))
        _ = try await y.registry.save(PROJProject(id: "fresh", name: "Made in Y", colour: "blue"))
        let startedY = try await CloudLeanFixture.start([y.adapter], on: y.mac)
        let sentY = startedY.sent.map { $0.entityId }
        #expect(sentY == ["project:fresh"], "Only what belongs to this Mac or to account Y goes into Y")
        let textY = CloudLeanFixture.text(startedY.sent)
        #expect(!textY.contains("Deck"), "Nothing of account X's record is in what Y receives, not even its edit")
        _ = try await y.registry.save(PROJProject(id: "deck", name: "Deck edited again", colour: "pink"))
        let laterY = try await CloudLeanFixture.sync(startedY.activation, on: y.mac)
        #expect(laterY.isEmpty, "A later edit of X's record is not sent into Y either")
        let listingY = try await y.adapter.listing()
        let said = listingY.notes.contains { $0.contains("another Cloud account") }
        #expect(said, "It is shown as kept on this Mac for another Cloud account: \(listingY.notes)")

        // A record with the same id arrives from account Y's Cloud: it is not merged with X's record on this Mac.
        let other = try CloudLeanProjectsTests.side(CloudLeanFixture.deviceB, clock: clock, subject: CloudLeanFixture.subjectY)
        defer { try? FileManager.default.removeItem(at: other.mac.root) }
        _ = try await other.registry.save(PROJProject(id: "deck", name: "Another deck, of account Y", colour: "green"))
        let fromOther = try await CloudLeanFixture.start([other.adapter], on: other.mac).sent
        let device = other.mac.device, adapterY = y.adapter
        await #expect(throws: CloudRecordRefusal.self) { try await CloudLeanFixture.deliver(fromOther, from: device, to: adapterY) }
        let untouched = try await project(y, "deck")
        #expect(untouched?.name == "Deck edited again" && untouched?.colour == "pink")
        await startedY.activation.stop()                              // signed out of Y

        // Back in account X: the record is X's and goes there with its edits; what was made in Y stays out of X.
        let back = try CloudLeanProjectsTests.side(CloudLeanFixture.deviceA, clock: clock, subject: CloudLeanFixture.subjectX, root: x.mac.root)
        let startedBack = try await CloudLeanFixture.start([back.adapter], on: back.mac)
        let sentBack = try await CloudLeanFixture.sync(startedBack.activation, on: back.mac)
        let all = startedBack.sent + sentBack
        let ids = all.map { $0.entityId }
        #expect(ids == ["project:deck"])
        let textBack = CloudLeanFixture.text(all)
        #expect(textBack.contains("Deck edited again") && !textBack.contains("Made in Y"))
    }

    @Test func signOutDeletesNothingAndStopsEveryCapture() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await CloudLeanAgentsTests.side(CloudLeanFixture.deviceA, clock: clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root) }
        _ = try await a.config.saveAgent(CloudLeanAgentsTests.agent("writer", "Writer", [("instructions", .string("Write plainly."))]))
        let started = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        #expect(started.sent.count == 2)
        await started.activation.stop()                               // sign-out

        // A save, a capture pass and an import after sign-out: nothing is captured, sent or applied.
        _ = try await a.config.saveAgent(CloudLeanAgentsTests.agent("writer", "Writer after sign-out", [("instructions", .string("Changed after sign-out."))]))
        let handed = try await started.activation.sync(outbox: a.mac.outbox)
        #expect(handed == 0)
        let after = await a.mac.outbox.take()
        #expect(after.isEmpty)
        let adapter = a.adapter, activation = started.activation, outbox = a.mac.outbox, earlier = started.sent
        await #expect(throws: CloudFailure.gateClosed) { try await adapter.captureLocal() }
        await #expect(throws: CloudFailure.gateClosed) { try await CloudLeanFixture.deliver(earlier, from: CloudLeanFixture.deviceB, to: adapter) }
        await #expect(throws: CloudFailure.gateClosed) { try await adapter.handOver(to: outbox) }
        await #expect(throws: CancellationError.self) { try await activation.start(outbox: outbox) }
        let unsent = try a.mac.store.ownUnhanded(domain: "agents", limit: 16)
        #expect(unsent.isEmpty, "No version is made after sign-out")
        let listing = try await a.adapter.listing()
        #expect(listing.keptCount == 0 && listing.waiting.isEmpty && listing.changes.isEmpty, "Nothing of a signed-out account is listed")

        // Nothing was deleted: the agent, its instructions, the bookkeeping and the origins are all still here.
        let kept = try await a.config.agent("writer")
        #expect(kept?["name"].string == "Writer after sign-out")
        #expect(kept?["instructions"].string == "Changed after sign-out.")
        #expect(FileManager.default.fileExists(atPath: a.mac.store.file.path))
        #expect(FileManager.default.fileExists(atPath: a.mac.root.appendingPathComponent("cloud").appendingPathComponent("a2-origins.json").path))
        let known = a.mac.origins.accounts(domain: "agents", entity: "agent:writer")
        #expect(known == [CloudLeanFixture.subjectX], "The record still remembers the account it went to")
    }

    @Test func aLostOriginsFileBesideAnotherAccountKeepsWhatWasHereOutOfTheNewAccount() async throws {
        let clock = CloudLeanFixture.Clock()
        let x = try CloudLeanProjectsTests.side(CloudLeanFixture.deviceA, clock: clock, subject: CloudLeanFixture.subjectX)
        defer { try? FileManager.default.removeItem(at: x.mac.root) }
        _ = try await x.registry.save(PROJProject(id: "deck", name: "Deck of account X", colour: "teal"))
        let startedX = try await CloudLeanFixture.start([x.adapter], on: x.mac)
        await startedX.activation.stop()
        try FileManager.default.removeItem(at: x.mac.root.appendingPathComponent("cloud").appendingPathComponent("a2-origins.json"))

        // Account Y on the same Mac, with the origins file gone and account X's folder still there.
        let y = try CloudLeanProjectsTests.side(CloudLeanFixture.deviceA, clock: clock, subject: CloudLeanFixture.subjectY, root: x.mac.root)
        #expect(y.mac.origins.lostBesideAnotherAccount)
        let startedY = try await CloudLeanFixture.start([y.adapter], on: y.mac)
        #expect(startedY.sent.isEmpty, "What was already on this Mac is treated as another account's, not sent")
        _ = try await y.registry.save(PROJProject(id: "later", name: "Made later", colour: "blue"))
        let later = try await CloudLeanFixture.sync(startedY.activation, on: y.mac)
        let ids = later.map { $0.entityId }
        #expect(ids == ["project:later"], "A project made afterwards belongs to this Mac and is sent")
    }
}
