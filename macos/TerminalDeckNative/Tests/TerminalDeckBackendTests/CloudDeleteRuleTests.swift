import Foundation
import Testing
@testable import TerminalDeckBackend

struct CloudDeleteRuleTests {
    private let now: Int64 = 1_900_000_000_000
    private let mac = "A4D541C1-B289-410D-828A-5028D805632F"
    private let otherMac = "5d0a2d02-dd37-49e8-89a7-d71b5c5d4402"
    private let group = "dd1c167a-86a7-4503-93ed-7c537acbfc09"

    private func intent(scope: CloudDeleteScope = .everywhere, by: CloudDeleteBy = .ai) -> CloudDeleteIntent {
        .init(place: "notes/plan.md", scope: scope, by: by, mac: mac,
              session: "Night work", agent: "Integrations", at: now, group: group)
    }
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-delete-rule-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func intentIsCodableAndKeepsTheWholeAttribution() throws {
        let original = intent()
        #expect(try JSONDecoder().decode(CloudDeleteIntent.self, from: JSONEncoder().encode(original)) == original)
    }

    @Test func memoryMarkerRoundTripsBothScopesAndAuthorsUsingTheSameSixFields() throws {
        for scope in CloudDeleteScope.allCases {
            for by in [CloudDeleteBy.person, .ai] {
                let original = intent(scope: scope, by: by)
                var fields = ["td_removed": String(now), "td_removed_by": mac, "td_removed_by_ai": "1"]
                CloudDeleteTravel.write(original, into: &fields)
                var marker = DeckMemoryFile(body: "Removed\n")
                for (key, value) in fields { marker.set(key, value) }
                let parsed = DeckMemoryFile(text: marker.text)
                let read = Dictionary(uniqueKeysWithValues: parsed.keys.compactMap { key in parsed.value(key).map { (key, $0) } })
                #expect(try CloudDeleteTravel.read(read, place: original.place, mac: mac, at: now) == .intent(original))
                #expect(read["td_removed"] == String(now))
                #expect(read["td_removed_by_ai"] == "1")
            }
        }
    }

    @Test func sealedFilePayloadRoundTripsAndKeepsExistingFields() throws {
        let original = intent(scope: .cloud)
        var payload = ["path": original.place, "origin_device": mac, "created_at": String(now)]
        CloudDeleteTravel.write(original, into: &payload)
        // JSON represents the plaintext payload before/after the file engine seals it; no key or account is used.
        let read = try JSONDecoder().decode([String: String].self, from: JSONEncoder().encode(payload))
        #expect(try CloudDeleteTravel.read(read, place: original.place, mac: mac, at: now) == .intent(original))
        #expect(read["path"] == original.place)
        #expect(Set(CloudDeleteTravel.fields) == Set(["td_delete_rule", "td_scope", "td_by", "td_session", "td_agent", "td_group"]))
    }

    @Test func aNewWriteClearsNamesLeftOverFromAnotherIntent() throws {
        var fields = ["td_session": "Old session", "td_agent": "Old agent"]
        let original = CloudDeleteIntent(place: "file", scope: .everywhere, by: .person, mac: mac, at: now, group: group)
        CloudDeleteTravel.write(original, into: &fields)
        #expect(fields["td_session"] == nil && fields["td_agent"] == nil)
        #expect(try CloudDeleteTravel.read(fields, place: "file", mac: mac, at: now) == .intent(original))
    }

    @Test func absenceOfTheRuleFieldAloneMeansOlderVersionInBothCarriers() throws {
        for fields in [["td_removed": String(now), "td_removed_by": mac], ["path": "file", "td_scope": "cloud"]] {
            #expect(try CloudDeleteTravel.read(fields, place: "file", mac: mac, at: now) == .olderVersion)
        }
    }

    @Test func malformedNewFieldsNeverBecomeAnOlderEverywhereDelete() throws {
        var fields: [String: String] = [:]
        CloudDeleteTravel.write(intent(), into: &fields)
        for key in [CloudDeleteTravel.scope, CloudDeleteTravel.by, CloudDeleteTravel.group, CloudDeleteTravel.rule] {
            var invalid = fields
            invalid[key] = "unknown"
            #expect(throws: CloudDeleteRuleError.invalidTravelFields) {
                _ = try CloudDeleteTravel.read(invalid, place: "file", mac: mac, at: now)
            }
        }
    }

    @Test func gateOpensForEveryFreshComputerAndCanonicalisesDeviceCase() {
        let announcements = [CloudDeleteGate.key(device: mac): CloudDeleteGate.value(at: now),
                             CloudDeleteGate.key(device: otherMac): CloudDeleteGate.value(at: now - 1000)]
        #expect(CloudDeleteGate.key(device: mac) == "onerule.understands.deleterule." + mac.lowercased())
        #expect(CloudDeleteGate.value(at: now) == "v1:1900000000000")
        #expect(CloudDeleteGate.isOpen(computers: [mac, otherMac], announcements: announcements, now: now))
    }

    @Test func gateClosesForAnUnannouncedComputerOrUnknownAccountOrClock() {
        let announcements = [CloudDeleteGate.key(device: mac): CloudDeleteGate.value(at: now)]
        #expect(!CloudDeleteGate.isOpen(computers: [mac, otherMac], announcements: announcements, now: now))
        #expect(!CloudDeleteGate.isOpen(computers: nil, announcements: announcements, now: now))
        #expect(!CloudDeleteGate.isOpen(computers: [], announcements: announcements, now: now))
        #expect(!CloudDeleteGate.isOpen(computers: [mac], announcements: announcements, now: nil))
        #expect(!CloudDeleteGate.isOpen(computers: [mac], announcements: announcements, now: 0))
    }

    @Test func noneExplicitlyExemptsAComputerWithoutExemptingOtherMissingComputers() {
        let announcements = [CloudDeleteGate.key(device: mac): CloudDeleteGate.value(at: now),
                             CloudDeleteGate.key(device: otherMac): CloudDeleteGate.none]
        #expect(CloudDeleteGate.isOpen(computers: [mac, otherMac], announcements: announcements, now: now))
        #expect(!CloudDeleteGate.isOpen(computers: [mac, otherMac, "unannounced"], announcements: announcements, now: now))
        #expect(CloudDeleteGate.isOpen(computers: [otherMac], announcements: announcements, now: now))
    }

    @Test func gateIncludesExactlyThreeDaysButRejectsOlderFutureMalformedAndUnknownFormats() {
        let key = CloudDeleteGate.key(device: mac)
        #expect(CloudDeleteGate.isOpen(computers: [mac], announcements: [key: CloudDeleteGate.value(at: now - CloudDeleteGate.freshFor)], now: now))
        for raw in [CloudDeleteGate.value(at: now - CloudDeleteGate.freshFor - 1), CloudDeleteGate.value(at: now + 1),
                    "v1:0", "v1:-1", "v1:garbage", "v2:1900000000000", "none:1900000000000"] {
            #expect(!CloudDeleteGate.isOpen(computers: [mac], announcements: [key: raw], now: now))
        }
    }

    @Test func marksAndIntentsSurviveReopeningTheFileOwnersState() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("folder.db").path
        let original = intent()
        let missing = CloudDeleteMark(place: original.place, mark: .notOnThisMac, at: now)
        let local = CloudDeleteMark(place: "private.md", mark: .onlyOnThisMac, at: now + 1)
        do {
            let db = try BackendCloudBrainFilesDatabase(path: path, engineTables: false)
            defer { db.close() }
            let state = try CloudDeleteState(files: db)
            try db.transaction {
                try state.putIntent(original)
                try state.putMark(missing)
                try state.putMark(local)
            }
        }
        let db = try BackendCloudBrainFilesDatabase(path: path, engineTables: false)
        defer { db.close() }
        let state = try CloudDeleteState(files: db)
        #expect(try state.intent(at: original.place) == original)
        #expect(try state.marks() == [missing, local])
        // Reading, and writing a new intent for the place, do not clear a local suppression mark.
        try state.putIntent(intent(scope: .cloud))
        #expect(try state.mark(at: original.place) == missing)
        try state.clearIntent(at: original.place)
        #expect(try state.intent(at: original.place) == nil)
        #expect(try state.mark(at: original.place) == missing)
        try state.clearMark(at: original.place)
        #expect(try state.marks() == [local])
    }

    @Test func memoryUsesItsAttachedStateAndKeepsBothMarksAcrossAReopen() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("memory.db").path
        let side = root.appendingPathComponent("memory-cloud.db").path
        let missing = CloudDeleteMark(place: "gone.md", mark: .notOnThisMac, at: now)
        let local = CloudDeleteMark(place: "local.md", mark: .onlyOnThisMac, at: now)
        do {
            let db = try DeckMemoryDatabase(path: path); defer { db.close() }
            try db.run("ATTACH DATABASE ? AS cloud", [.text(side)])
            let state = try CloudDeleteState(memory: db)
            try state.putMark(missing)
            try state.putMark(local)
            try state.putIntent(intent())
            #expect(try db.first("SELECT name FROM main.sqlite_master WHERE name='cloud_delete_marks'") == nil)
            #expect(try db.first("SELECT name FROM main.sqlite_master WHERE name='cloud_delete_intents'") == nil)
        }
        let db = try DeckMemoryDatabase(path: path); defer { db.close() }
        try db.run("ATTACH DATABASE ? AS cloud", [.text(side)])
        let state = try CloudDeleteState(memory: db)
        #expect(try state.mark(at: "gone.md") == missing)
        #expect(try state.mark(at: "local.md") == local)
        #expect(try state.intent(at: intent().place) == intent())
    }

    @Test func sharedConnectionJoinsTheOwnersRollbackAndNeverFallsBackToMemoryMain() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let memory = try DeckMemoryDatabase(path: root.appendingPathComponent("memory.db").path)
        defer { memory.close() }
        #expect(throws: CloudDeleteRuleError.invalidState) { _ = try CloudDeleteState(memory: memory) }
        let db = try BackendCloudBrainFilesDatabase(path: root.appendingPathComponent("folder.db").path, engineTables: false)
        defer { db.close() }
        let state = try CloudDeleteState(files: db)
        #expect(throws: CloudDeleteRuleError.invalidState) {
            try db.transaction {
                try state.putIntent(intent())
                try state.putMark(.init(place: "file", mark: .notOnThisMac, at: now))
                throw CloudDeleteRuleError.invalidState
            }
        }
        #expect(try state.intent(at: intent().place) == nil)
        #expect(try state.marks().isEmpty)
    }

    private actor Witness: CloudDeleteWitness {
        private(set) var calls: [(URL, Date, Date)] = []
        let answer: CloudDeleteWitnessAnswer
        init(answer: CloudDeleteWitnessAnswer) { self.answer = answer }
        func who(removed path: URL, lastSeen: Date, seenGoneAt: Date) async -> CloudDeleteWitnessAnswer {
            calls.append((path, lastSeen, seenGoneAt))
            return answer
        }
    }

    @Test func witnessSlotDefaultsToByHandInstallsOnceAndForwardsBothTimes() async {
        let slot = CloudDeleteWitnessSlot()
        let path = URL(fileURLWithPath: "/scratch/notes/plan.md")
        let seen = Date(timeIntervalSince1970: 10), gone = Date(timeIntervalSince1970: 12)
        #expect(await slot.who(removed: path, lastSeen: seen, seenGoneAt: gone) == .cannotKnow)
        let answer = CloudDeleteWitnessAnswer.ai(session: "Night work", agent: "Integrations", command: seen, group: group)
        let witness = Witness(answer: answer)
        #expect(slot.installOnce(witness))
        #expect(!slot.installOnce(CloudDeleteUnknownWitness()))
        #expect(await slot.who(removed: path, lastSeen: seen, seenGoneAt: gone) == answer)
        let calls = await witness.calls
        #expect(calls.count == 1)
        #expect(calls.first?.0 == path && calls.first?.1 == seen && calls.first?.2 == gone)
        #expect(await slot.who(removed: path, lastSeen: gone, seenGoneAt: seen) == .cannotKnow)
        #expect(CloudDeleteWitnessAnswer.notAI.by == .person)
        #expect(CloudDeleteWitnessAnswer.cannotKnow.by == .person)
        #expect(answer.by == .ai)
    }

    @Test func binGroupsKeepNamesCountsAndOneGroupAcrossKinds() {
        let actor = CloudDeleteActor(by: .ai, mac: mac, macName: "Mac mini", session: "Night work", agent: "Integrations", at: now, group: group)
        let items = [CloudDeleteItem(id: "memory-key", kind: "memory", name: "Plan", place: "plan.md"),
                     CloudDeleteItem(id: "task-key", kind: "task", name: "Write a plan")]
        #expect(actor.intent(place: "plan.md", scope: .everywhere).group == actor.intent(place: "task-key", scope: .everywhere).group)
        let bin = CloudBinGroup(id: group, by: actor.by, macName: actor.macName, session: actor.session, agent: actor.agent,
                                at: now, items: items)
        #expect(bin.count == 2 && bin.items == items)
        #expect(bin.session == "Night work" && bin.agent == "Integrations" && bin.at == now)
        #expect(bin.title == "Removed by an AI on Mac mini")
        #expect(CloudBinGroup(id: group, by: .person, macName: "MacBook Pro", at: now, items: items).title == "Removed on MacBook Pro")
        #expect(CloudBinGroup(id: group, by: .person, macName: "MacBook Pro", at: now, items: items, era: .olderVersion).title == "Removed on MacBook Pro (older version)")
        #expect(CloudBinGroup(id: group, by: .person, macName: "MacBook Pro", at: now, items: items, era: .beforeNewRule).title == "Before the new rule")
    }

    @Test func wordsAreTheAgreedWordsAndRetentionIsThirtyDays() {
        #expect(CloudDeleteWords.notOnThisMac == "Not on this Mac")
        #expect(CloudDeleteWords.bringBack == "Bring back")
        #expect(CloudDeleteWords.bringAllBack == "Bring all back")
        #expect(CloudDeleteWords.onlyOnThisMac == "Only on this Mac")
        #expect(CloudDeleteWords.putInCloudAgain == "Put in Cloud again")
        #expect(CloudDeleteWords.removedByAI(on: "Mac mini") == "Removed by an AI on Mac mini")
        #expect(CloudDeleteWords.removed(on: "Mac mini") == "Removed on Mac mini")
        #expect(CloudDeleteWords.removedOlderVersion(on: "Mac mini") == "Removed on Mac mini (older version)")
        #expect(CloudDeleteWords.beforeNewRule == "Before the new rule")
        #expect(CloudDeleteWords.putBackAll == "Put back all")
        #expect(CloudDeleteWords.cloud == "Cloud")
        #expect(CloudDeleteWords.everywhere == "Everywhere")
        #expect(CloudDeleteWords.cloudNeedsUpdatedMacs == "Cloud only works once your other devices are updated")
        #expect(CloudLocalMark.notOnThisMac.title == CloudDeleteWords.notOnThisMac)
        #expect(CloudLocalMark.onlyOnThisMac.title == CloudDeleteWords.onlyOnThisMac)
        #expect(CloudBinGroup.retentionMilliseconds == 2_592_000_000)
        #expect(CloudDeleteGate.renewAfter == 43_200_000)
    }
}
