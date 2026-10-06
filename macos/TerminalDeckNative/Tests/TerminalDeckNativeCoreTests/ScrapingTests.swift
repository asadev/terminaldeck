import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Mirrors scraping-view.test.ts, and the readers from scraping-bridge.test.ts.

@Suite("Settings → Scraping")
struct ScrapingTests {
    private func json(_ text: String) -> CodingAIJSON { CodingAIJSON.parse(text) }
    private let profiles = [
        ScrapingProfile(id: "a", name: "Alpha", avatar: "", isDefault: true),
        ScrapingProfile(id: "b", name: "Beta", avatar: "", isDefault: false),
        ScrapingProfile(id: "c", name: "Gamma", avatar: "🐙", isDefault: false),
    ]

    @Test func countsAndSizes() {
        #expect(Scraping.countLine(nil, "worker", "workers") == "not measured (workers)")
        #expect(Scraping.countLine(0, "worker", "workers") == "0 workers", "a real zero is a measurement")
        #expect(Scraping.countLine(1, "worker", "workers") == "1 worker")
        #expect(Scraping.countLine(16498, "row", "rows").hasPrefix("16"))
        #expect(Scraping.bytesLine(nil) == "not measured")
        #expect(Scraping.bytesLine(2048) == "2.0 KB")
    }

    @Test func requestRules() {
        #expect(Scraping.fulfillNote.contains("Block stops the request"))
        #expect(Scraping.resourceTypes.map(Scraping.resourceLabel) == ["Images", "Media", "Fonts", "Stylesheets", "Scripts", "XHR", "Fetch"])
        #expect(Scraping.requestRules.map(Scraping.ruleLabel) == ["Allow", "Block", "Fulfill"])
    }

    @Test func workerRows() {
        #expect(Scraping.workerRows(fleet: nil, status: nil, profiles: profiles).isEmpty)
        let fleet = ScrapingFleet(profileIds: ["b", "gone", "a"], concurrency: 2, delayMs: 0)
        let unreported = Scraping.workerRows(fleet: fleet, status: nil, profiles: profiles)
        #expect(unreported.map(\.state) == ["unreported", "unreported", "unreported"], "never invents idle")
        #expect(unreported.map(\.profileId) == ["b", "gone", "a"], "fleet order kept")
        #expect(unreported[1].orphaned && unreported[1].name == "gone")
        let status = ScrapingStatus(workers: [ScrapingWorkerState(profileId: "a", state: "busy", requests: 7),
                                              ScrapingWorkerState(profileId: "c", state: "idle", requests: nil)])
        let rows = Scraping.workerRows(fleet: fleet, status: status, profiles: profiles)
        #expect(rows[2].state == "busy" && rows[2].requests == 7)
        #expect(rows.last?.profileId == "c" && rows.last?.enrolled == false, "a running worker nobody enrolled still shows")
        #expect(Scraping.fleetLine(rows, measured: false) == "4 workers · busy not measured")
        #expect(Scraping.fleetLine(rows, measured: true) == "4 workers · 1 busy")
        #expect(Scraping.enrollable(fleet: fleet, profiles: profiles).map(\.id) == ["c"])
        #expect(Scraping.workerStateLabel("unreported") == "Not reported")
    }

    @Test func liftsAndAsks() {
        #expect(Scraping.liftLine(from: "Alpha", into: ["Beta"]) == "Copy the signed-in session from Alpha into Beta.")
        #expect(Scraping.liftLine(from: "Alpha", into: ["Beta", "Gamma", "Delta"]) == "Copy the signed-in session from Alpha into Beta, Gamma and Delta.")
        #expect(Scraping.liftRequestLine(askedBy: "Hoot", from: "Alpha", into: ["Beta"]) == "Hoot asked to copy the signed-in session from Alpha into Beta.")
        #expect(Scraping.liftRequestLine(askedBy: "  ", from: "A", into: ["B"]).hasPrefix("Something asked to"))
        let asks = Scraping.liftRequests(json(#"[{"id":"1","fromProfileId":"a","intoProfileIds":["b"],"askedBy":"Hoot","at":5},{"id":"2","fromProfileId":"a","intoProfileIds":[]},{"fromProfileId":"a","intoProfileIds":["b"]}]"#))
        #expect(asks.map(\.id) == ["1"])
    }

    @Test func coverageAndDrops() {
        #expect(Scraping.coverageVerdict(stated: nil, got: nil, ran: false) == ("unknown", "No check has run."))
        #expect(Scraping.coverageVerdict(stated: nil, got: 5, ran: true).tone == "unknown")
        #expect(Scraping.coverageVerdict(stated: 10, got: nil, ran: true).line == "The page stated 10; nothing counted what was taken.")
        #expect(Scraping.coverageVerdict(stated: 200, got: 150, ran: true) == ("short", "150 of 200 stated — 75%."))
        #expect(Scraping.coverageVerdict(stated: 200, got: 200, ran: true).tone == "complete")
        #expect(Scraping.droppedLine(dropped: nil, reason: "", measured: true) == "Dropped: not measured.")
        #expect(Scraping.droppedLine(dropped: 0, reason: "", measured: true) == "Nothing dropped.")
        #expect(Scraping.droppedLine(dropped: 3, reason: "the size cap", measured: true) == "3 responses dropped — the size cap.")
    }

    @Test func storeTools() {
        let digest = String(repeating: "a", count: 64)
        let tools = Scraping.tools(json("""
        {"view":{"tools":[{"id":"t1","name":"Lister","state":"available","sha256":"\(digest)","grants":["page-read"],"origins":["*"]},
        {"id":"t2","state":"installed"},{"id":"t3","state":"available","sha256":"nope"},{"id":"t4","state":"damaged"}]},"orphans":["old"]}
        """))
        #expect(tools.map(\.id) == ["t1", "t2", "t3", "t4", "old"])
        #expect(Scraping.canInstall(tools[0]) && !Scraping.canInstall(tools[1]))
        #expect(Scraping.reachLine(tools[0]) == "Reads the page you point it at · Runs on any site")
        #expect(Scraping.reachLine(tools[1]) == "It does not declare what it reaches.")
        #expect(Scraping.installBlockedReason(tools[2]) == "This tool is not signed, so it cannot be installed.")
        #expect(tools[3].installed && tools[3].identity == "mismatch", "a damaged install is installed, so it offers Remove")
        let mismatch = ScrapingTool(id: "x", name: "x", version: "", publisher: "", reach: [], installed: false, identity: "mismatch")
        #expect(Scraping.installBlockedReason(mismatch) == "What arrived is not what this listing signed. It will not install.")
        #expect(tools[4].installed && tools[4].identity == "unknown")
    }

    @Test func scopeMintAndInitials() {
        #expect(Scraping.scopeLabel(browserWide: false, profileName: "Beta") == "Beta")
        #expect(Scraping.scopeLabel(browserWide: false, profileName: "") == "This profile")
        #expect(Scraping.scopeLabel(browserWide: true, profileName: "Beta") == "This browser")
        #expect(Scraping.mintPlan("x", have: 2).total == nil)
        #expect(Scraping.mintPlan("2", have: 2).total == nil, "no button when it would add nothing")
        #expect(Scraping.mintPlan("6", have: 2) == (6, "2 workers now, so this makes 4 more."))
        #expect(Scraping.initial("beta", avatar: "") == "B")
        #expect(Scraping.initial("Gamma", avatar: "🐙") == "🐙")
    }

    @Test func readers() {
        let config = Scraping.config(json(#"{"fleet":{"profileIds":["a",""],"concurrency":3,"delayMs":-1},"requests":{"image":"block","font":"nope"},"capture":{"on":true,"directory":"/x","keepMB":10}}"#))
        #expect(config?.fleet?.profileIds == ["a"] && config?.fleet?.delayMs == nil, "a negative count is not a measurement")
        #expect(config?.requests?["image"] == "block" && config?.requests?["font"] == .some(nil))
        #expect(config?.capture?.on == true && config?.assets == nil)
        #expect(Scraping.config(json("{}")) == nil)
        let fleet = Scraping.configFromWorkers(json(#"{"workers":[{"profileId":"a"},{"profileId":""}],"pace":{"maxConcurrent":4,"minDelayMs":250}}"#))?.fleet
        #expect(fleet == ScrapingFleet(profileIds: ["a"], concurrency: 4, delayMs: 250))
        #expect(Scraping.outcome(.null).message == "No answer came back, so nothing here is confirmed.")
        #expect(Scraping.outcome(json(#"{"ok":true}"#)).message == "Done.")
        #expect(Scraping.retiredNote(name: "Beta", stored: ["b"], id: "b") == "Beta is still a worker — the engine did not retire it.")
        #expect(Scraping.enrolledNote(name: "Alpha", stored: [], id: "a").hasPrefix("Alpha was not enrolled."))
    }
}
