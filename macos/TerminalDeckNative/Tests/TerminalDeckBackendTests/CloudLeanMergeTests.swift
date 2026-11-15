import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Lane A2 lean item 4: two Macs change the same thing. The merge core's rule as built: per field the newest wins,
/// the other value is kept and carried. No screen for choosing: one read-only tool gives the count and a plain list.
@Suite("Cloud lean — two Macs change the same thing: newest wins per field, the other version is kept and listed")
struct CloudLeanMergeTests {
    private func name(_ side: CloudLeanProjectsTests.Side, _ id: String) async throws -> PROJProject? {
        let projects = try await side.registry.projects()
        return projects.first { $0.id == id }
    }

    @Test func theNewestNameWinsOnBothMacsAndTheOtherIsKeptCarriedAndListed() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try CloudLeanProjectsTests.side(CloudLeanFixture.deviceA, clock: clock), b = try CloudLeanProjectsTests.side(CloudLeanFixture.deviceB, clock: clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await a.registry.save(PROJProject(id: "deck", name: "Deck", colour: "teal"))
        let startedA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        let startedB = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: b.adapter)

        // Both rename it while apart: A first, B a moment later.
        _ = try await a.registry.save(PROJProject(id: "deck", name: "Deck A", colour: "teal"))
        let fromA = try await CloudLeanFixture.sync(startedA.activation, on: a.mac)
        _ = try await b.registry.save(PROJProject(id: "deck", name: "Deck B", colour: "teal"))
        let fromB = try await CloudLeanFixture.sync(startedB.activation, on: b.mac)
        #expect(fromA.count == 1 && fromB.count == 1)
        try await CloudLeanFixture.deliver(fromA, from: a.mac.device, to: b.adapter)
        try await CloudLeanFixture.deliver(fromB, from: b.mac.device, to: a.adapter)

        let onA = try await name(a, "deck"), onB = try await name(b, "deck")
        #expect(onA?.name == "Deck B", "The newest change wins on the Mac that lost")
        #expect(onB?.name == "Deck B", "and stays on the Mac that won")

        // The other value is kept, and listed: by count on both, with its text only on the Mac it came from.
        let listingB = try await b.adapter.listing()
        #expect(listingB.keptCount == 1)
        #expect(listingB.kept.first?.field == "name")
        #expect(listingB.kept.first?.device == a.mac.device)
        #expect(listingB.kept.first?.mine == false)
        #expect(listingB.kept.first?.preview == nil, "A value from another device is never returned")
        let listingA = try await a.adapter.listing()
        #expect(listingA.keptCount == 1)
        #expect(listingA.kept.first?.mine == true)
        #expect(listingA.kept.first?.preview == "Deck A")

        // The one read-only tool, for lane A's page.
        let toolB = BackendCloudLeanTools(adapters: [b.adapter]), toolA = BackendCloudLeanTools(adapters: [a.adapter])
        let answerB = try await toolB.invoke(BackendCloudLeanTools.toolID, arguments: CloudValue(.object([])))
        #expect(answerB.raw["keptCount"].number == 1)
        #expect(answerB.raw["sentence"].string == "1 earlier version kept.")
        #expect(!answerB.raw.compact.contains("Deck A"), "The tool never returns another device's kept text")
        let answerA = try await toolA.invoke(BackendCloudLeanTools.toolID, arguments: CloudValue(.object([.init("row", .string("projects"))])))
        #expect(answerA.raw.compact.contains("Deck A"), "This Mac's own kept value is shown to it")
        let countsB = try await toolB.counts()
        #expect(countsB.kept == 1)
        await #expect(throws: CloudFailure.self) { try await toolB.invoke("cloud.versions.choose", arguments: CloudValue(.object([]))) }
        await #expect(throws: CloudFailure.self) { try await toolB.invoke(BackendCloudLeanTools.toolID, arguments: CloudValue(.object([.init("use", .string("Deck A"))]))) }
        let tool = BackendCloudLeanTools.contribution.tools.first
        #expect(tool?.mutates == false, "The tool is read only: nothing is chosen or approved through it")
        #expect(BackendCloudLeanTools.contribution.actions.isEmpty)

        // Nothing goes back and forth afterwards.
        let againA = try await CloudLeanFixture.sync(startedA.activation, on: a.mac), againB = try await CloudLeanFixture.sync(startedB.activation, on: b.mac)
        #expect(againA.isEmpty && againB.isEmpty)

        // The kept version is carried: a later change to another field does not drop it.
        _ = try await a.registry.save(PROJProject(id: "deck", name: "Deck B", colour: "green"))
        let later = try await CloudLeanFixture.sync(startedA.activation, on: a.mac)
        try await CloudLeanFixture.deliver(later, from: a.mac.device, to: b.adapter)
        let afterB = try await name(b, "deck")
        #expect(afterB?.colour == "green")
        #expect(afterB?.name == "Deck B")
        let carried = try await b.adapter.listing()
        #expect(carried.keptCount == 1, "The earlier version is still kept after an unrelated later edit")
    }

    @Test func changesToDifferentFieldsBothSurviveAndNothingIsKept() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try CloudLeanProjectsTests.side(CloudLeanFixture.deviceA, clock: clock), b = try CloudLeanProjectsTests.side(CloudLeanFixture.deviceB, clock: clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await a.registry.save(PROJProject(id: "deck", name: "Deck", icon: "folder", colour: "teal"))
        let startedA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        let startedB = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: b.adapter)

        _ = try await a.registry.save(PROJProject(id: "deck", name: "Deck", icon: "terminal", colour: "teal"))
        let fromA = try await CloudLeanFixture.sync(startedA.activation, on: a.mac)
        _ = try await b.registry.save(PROJProject(id: "deck", name: "Deck", icon: "folder", colour: "pink"))
        let fromB = try await CloudLeanFixture.sync(startedB.activation, on: b.mac)
        try await CloudLeanFixture.deliver(fromB, from: b.mac.device, to: a.adapter)
        try await CloudLeanFixture.deliver(fromA, from: a.mac.device, to: b.adapter)
        let onA = try await name(a, "deck"), onB = try await name(b, "deck")
        #expect(onA?.icon == "terminal" && onA?.colour == "pink")
        #expect(onB?.icon == "terminal" && onB?.colour == "pink")
        let keptA = try await a.adapter.listing(), keptB = try await b.adapter.listing()
        #expect(keptA.keptCount == 0 && keptB.keptCount == 0)
    }

    @Test func twoMacsEditTheSameInstructionsTheNewestIsShownAndTheOtherTextIsKeptOnItsOwnMacOnly() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await CloudLeanAgentsTests.side(CloudLeanFixture.deviceA, clock: clock), b = try await CloudLeanAgentsTests.side(CloudLeanFixture.deviceB, clock: clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await a.config.saveAgent(CloudLeanAgentsTests.agent("writer", "Writer", [("instructions", .string("First text."))]))
        let startedA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        let startedB = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: b.adapter)

        _ = try await a.config.saveAgent(CloudLeanAgentsTests.agent("writer", "Writer", [("instructions", .string("Text written on Mac A."))]))
        let fromA = try await CloudLeanFixture.sync(startedA.activation, on: a.mac)
        _ = try await b.config.saveAgent(CloudLeanAgentsTests.agent("writer", "Writer", [("instructions", .string("Text written on Mac B."))]))
        let fromB = try await CloudLeanFixture.sync(startedB.activation, on: b.mac)
        let sentA = fromA.map { $0.entityId }, sentB = fromB.map { $0.entityId }
        #expect(sentA == ["instruction:writer.md"] && sentB == ["instruction:writer.md"], "Only the text changed: \(sentA) \(sentB)")
        try await CloudLeanFixture.deliver(fromA, from: a.mac.device, to: b.adapter)
        try await CloudLeanFixture.deliver(fromB, from: b.mac.device, to: a.adapter)

        let onA = try await a.config.agent("writer"), onB = try await b.config.agent("writer")
        #expect(onA?["instructions"].string == "Text written on Mac B.")
        #expect(onB?["instructions"].string == "Text written on Mac B.")
        let toolB = BackendCloudLeanTools(adapters: [b.adapter]), toolA = BackendCloudLeanTools(adapters: [a.adapter])
        let answerB = try await toolB.invoke(BackendCloudLeanTools.toolID, arguments: CloudValue(.object([])))
        #expect(answerB.raw["keptCount"].number == 1)
        #expect(!answerB.raw.compact.contains("Mac A"), "Another device's kept text is never in the tool's answer")
        let answerA = try await toolA.invoke(BackendCloudLeanTools.toolID, arguments: CloudValue(.object([])))
        #expect(answerA.raw["keptCount"].number == 1)
        #expect(answerA.raw.compact.contains("Text written on Mac A."), "This Mac's own earlier text is still here to be read")
    }
}
