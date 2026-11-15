import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// "See what is in your Cloud": the page's model for each part, from the fixture account (items from two devices;
/// going up, not sent, waiting here, held, refused; a device never seen). Names and times only.
@Suite("Cloud contents — devices, everything in your Cloud, activity")
struct CloudContentsTests {
    let now: Int64 = 1_794_000_000_000
    typealias F = BackendCloudContentsFixture
    func built(behind: Int = 0) throws -> (model: BackendCloudContents, handles: [String: BackendCloudContentsHandle]) {
        try #require(BackendCloudContentsBuilder.build(contents: F.contents(now: now), snapshot: F.snapshot(now: now, behind: behind), names: F.names, now: now))
    }

    @Test func nothingIsBuiltWhenSignedOut() {
        let signedOut = CloudAccountSnapshot(phase: .signedOut, gate: .closed)
        #expect(BackendCloudContentsBuilder.build(contents: F.contents(now: now), snapshot: signedOut, now: now) == nil)
        let closed = CloudAccountSnapshot(phase: .signedIn, gate: .closed)
        #expect(BackendCloudContentsBuilder.build(contents: F.contents(now: now), snapshot: closed, now: now) == nil)
    }

    @Test func devicesShowNamesDatesAndOnePlainState() throws {
        let devices = try built().model.devices
        #expect(devices.map(\.name) == ["Studio Mac", "MacBook Pro", "Office iMac", "Mac mini"])
        #expect(devices.map(\.isThisMac) == [true, false, false, false])
        #expect(devices[0].state == "Sending 1 change")
        #expect(devices[0].moving)
        #expect(devices[0].lastSent == now - 30 * 60_000)
        #expect(devices[0].lastReceived == now - 19 * 60_000)
        // MacBook Pro checked in a minute ago, after everything: up to date. It sent its last pack 20 minutes ago.
        #expect(devices[1].state == "Up to date")
        #expect(devices[1].lastSent == now - 20 * 60_000)
        #expect(devices[2].state == "Not seen yet")
        #expect(devices[3].state == "Waiting: this Mac does not trust it yet")
        #expect(devices[3].needsLook)
        // Nothing going up and the Cloud ahead: receiving.
        var quiet = F.contents(now: now)
        quiet = CloudSyncContents(thisDevice: quiet.thisDevice, items: quiet.items, packs: quiet.packs, held: quiet.held, refused: quiet.refused)
        let receiving = try #require(BackendCloudContentsBuilder.build(contents: quiet, snapshot: F.snapshot(now: now, behind: 12), names: F.names, now: now))
        #expect(receiving.model.devices[0].state == "Catching up: 12 changes still to fetch")
        let level = try #require(BackendCloudContentsBuilder.build(contents: quiet, snapshot: F.snapshot(now: now), names: F.names, now: now))
        #expect(level.model.devices[0].state == "Up to date")
        // A device last seen days ago.
        let later = try #require(BackendCloudContentsBuilder.build(contents: quiet, snapshot: F.snapshot(now: now), names: F.names, now: now + 5 * 86_400_000))
        #expect(later.model.devices[1].state.hasPrefix("Not seen since "))
    }

    @Test func theBrowserListsEveryKindWithNamesPlacesAndDevices() throws {
        let (model, handles) = try built()
        #expect(model.kinds == [.memory, .projects, .agents, .instructionFiles, .tasks, .settings, .artifacts, .cloudFolder, .passwords])
        #expect(model.counts[.memory] == 4) // CLOUD-FILES-4: the notes index rows are never counted
        #expect(model.counts[.instructionFiles] == 1)
        #expect(model.counts[.passwords] == 1)
        let claude = try #require(model.items(.instructionFiles).first)
        #expect(claude.name == "Instructions for Claude") // CLOUD-FILES-4: what it is, not its file name
        #expect(claude.fileName == "CLAUDE.md")
        #expect(claude.place == "Terminal Deck")
        #expect(claude.changedBy == "MacBook Pro")
        #expect(claude.history.map(\.device) == ["MacBook Pro", "Studio Mac"])
        #expect(claude.presence == ["On this Mac", "On MacBook Pro", "Waiting on Office iMac", "Waiting on Mac mini"])
        #expect(claude.isText)
        #expect(handles[claude.id]?.projectId == F.project)
        #expect(handles[claude.id]?.relative == "CLAUDE.md")
        // Newest first.
        let memory = model.items(.memory)
        #expect(memory.map(\.changedAt) == memory.map(\.changedAt).sorted(by: >))
        #expect(memory.first?.name == "Plan")
        #expect(memory.first?.presence.first == "Sending from this Mac")
        // CLOUD-FILES-4: the memory's own index of notes is never a row (each note is its own row already).
        #expect(!memory.contains { $0.name == "Notes" })
        let todo = try #require(memory.first { $0.name == "Todo" })
        #expect(todo.presence.first == "Waiting on this Mac")
        #expect(todo.note == "Waiting: its project is not on this Mac yet")
        let big = try #require(memory.first { $0.name == "Big export" })
        #expect(big.note == "Could not send: the service refused this edit")
        #expect(model.items(.projects).map(\.name) == ["Terminal Deck"])
        #expect(model.items(.agents).map(\.name) == ["Decker"])
        #expect(model.items(.settings).map(\.name) == ["Shared memory settings"])
        // A saved password by its kind; never a value, never a preview.
        let password = try #require(model.items(.passwords).first)
        #expect(password.name == "Server login")
        #expect(!password.isText)
        // Search and the device filter.
        #expect(model.items(.memory, search: "plan").map(\.name) == ["Plan"])
        #expect(model.items(.memory, device: "MacBook Pro").allSatisfy { $0.onDevices.contains("MacBook Pro") || $0.history.contains { $0.device == "MacBook Pro" } })
        #expect(!model.items(.memory, device: "MacBook Pro").contains { $0.name == "Plan" })
        // Ids stay put across builds (a selection survives the live refresh).
        #expect(try built().model.items.map(\.id) == model.items.map(\.id))
    }

    @Test func activityIsPlainSentencesNewestFirst() throws {
        let activity = try built().model.activity
        let texts = activity.map(\.text)
        #expect(texts.contains("MacBook Pro sent Instructions for Claude for Terminal Deck"))
        #expect(texts.contains("Studio Mac received Instructions for Claude for Terminal Deck from MacBook Pro"))
        #expect(texts.contains("Studio Mac sent 4 memory entries"))
        #expect(texts.contains("MacBook Pro sent Session notes for Terminal Deck"))
        #expect(texts.contains("Held: 2 items from a device this Mac does not trust yet"))
        #expect(texts.contains("Could not use: 1 change from Cloud could not be checked"))
        #expect(texts.contains("Could not send: the service refused this edit"))
        #expect(activity.map(\.at) == activity.map(\.at).sorted(by: >))
        #expect(activity.filter(\.problem).count == 3)
    }

    @Test func noCodeIdOrHashReachesTheModelOrTheTool() throws {
        let model = try built().model
        let wire = model.wireValue().compact
        let secrets = [F.mac, F.pro, F.imac, F.mini, F.project, F.agent, F.password, "AAAA BBBB", "key-mac", "E_QUOTA_42", "0a1b2c3d4e5f",
                       String(repeating: "ab", count: 32), String(repeating: "cd", count: 32), "signature", "files/I09", "brain/"]
        for text in model.allText + [wire] {
            for secret in secrets { #expect(!text.contains(secret), "\(secret) reached: \(text)") }
            #expect(!BackendCloudContentsWords.looksLikeCode(text) || text == wire, "looks like a code: \(text)")
        }
        #expect(BackendCloudContentsWords.looksLikeCode(F.project))
        #expect(BackendCloudContentsWords.looksLikeCode("3f2a9c0d1e4b5a6f"))
        #expect(!BackendCloudContentsWords.looksLikeCode("2026-11-12-session-notes.md"))
        #expect(BackendCloudContentsWords.plain("A " + F.pro) == nil)
    }

    @Test func timesReadPlainly() {
        let calendar = Calendar(identifier: .gregorian)
        let today = Date(timeIntervalSince1970: Double(now) / 1000)
        #expect(BackendCloudContentsWords.time(now, now: today, calendar: calendar).hasPrefix("Today, "))
        #expect(BackendCloudContentsWords.time(now - 86_400_000, now: today, calendar: calendar).hasPrefix("Yesterday, "))
    }
}
