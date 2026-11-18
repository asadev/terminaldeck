import CryptoKit
import Foundation
import Testing
@testable import TerminalDeckBackend
@testable import TerminalDeckNativeCore

/// WhatsApp agents' engine (DESIGN-WHATSAPP.md second version) against a fake WhatsApp, fake receivers and a fake pair
/// of computers sharing one synced settings store. No network, no Keychain, no screen. Keys are made up.
@Suite struct WhatsAppEngineTests {
    static let keyA = "made-up-whatsapp-key-aaaaaaaaaaaaaaaa"
    static let keyB = "made-up-whatsapp-key-bbbbbbbbbbbbbbbb"
    static let refused = "made-up-whatsapp-key-refused"
    static let him = "user:1555000111"

    // MARK: Profiles

    @Test func aRefusedKeyAddsNothingAndTheFirstAcceptedOneIsReceivedByHoot() async throws {
        let w = WAWorld()
        let a = w.engine(w.macA)
        await #expect(throws: WhatsAppProblem.keyRefused) { try await a.add(name: "Phone", key: Self.refused) }
        #expect(await a.agents().isEmpty)
        let first = try await a.add(name: "", key: Self.keyA)
        #expect(first.name == "WhatsApp agent" && first.receiver == .hoot && first.state == .waiting && first.sending)
        let second = try await a.add(name: "", key: Self.keyB)
        #expect(second.name == "WhatsApp agent 2" && second.receiver == .nowhere)
        await a.stop()
    }

    @Test func anyNumberOfAgentsCanBeAdded() async throws {
        let w = WAWorld()
        let a = w.engine(w.macA)
        for n in 0..<7 { _ = try await a.add(name: "Agent \(n)", key: "made-up-whatsapp-key-number-\(n)") }
        #expect(await a.agents().count == 7)
        #expect(await a.agents().canAdd)
        await a.stop()
    }

    @Test func theKeyIsNeverInTheSyncedRecordTheListOrAToolAnswer() async throws {
        let w = WAWorld()
        let a = w.engine(w.macA)
        let added = try await a.add(name: "Phone", key: Self.keyA)
        #expect(try await w.keys.key(added.id) == Self.keyA)
        let synced = try JSONEncoder().encode(await w.settings.records())
        #expect(!String(decoding: synced, as: UTF8.self).contains(Self.keyA))
        let listed = try JSONEncoder().encode(await a.agents())
        #expect(!String(decoding: listed, as: UTF8.self).contains(Self.keyA))
        let wire = BackendWhatsAppTools.wire(try #require(await a.agents().first)).compact
        #expect(!wire.contains(Self.keyA))
        #expect(!BackendWhatsAppTools.redacted(.object([.init("apiKey", .string(Self.keyA))])).compact.contains(Self.keyA))
        await a.stop()
    }

    // MARK: Messages (the link, driven directly)

    @Test func theFirstConnectAnswersNothingFromTheBacklog() async throws {
        let w = WAWorld()
        let box = WARecordBox(.init(id: "wa-1", name: "Phone", receiver: .hoot, readerID: "a", addedAt: 0))
        await w.wa.queue([.messages([w.text("old-1", "hello from last week", ago: 3600), w.text("old-2", "and this", ago: 60)], next: 2), .nothing])
        let link = w.link(box)
        await link.start()
        try await w.until { await box.record.offset == 2 }
        await link.stop()
        #expect(await box.record.creator == Self.him)
        #expect(await w.wa.sent.isEmpty)
        #expect(await w.receivers.said.isEmpty)
    }

    @Test func aTextBecomesAMessageInTheReceiverAndTheAnswerGoesBackFormattedAndSplit() async throws {
        let w = WAWorld()
        let box = WARecordBox(.init(id: "wa-1", name: "Phone", receiver: .hoot, readerID: "a", creator: Self.him, offset: 5, addedAt: 0))
        let link = w.link(box)
        await w.receivers.setTurn(.init(turnID: "t0", state: .done(answer: "an old answer")))
        await link.take(w.text("m1", "what is running?"))
        #expect(await w.receivers.said.map(\.text) == ["what is running?"])
        #expect(await w.wa.reads.contains { $0.id == "m1" && $0.typing })
        await w.receivers.setTurn(.init(turnID: "t1", state: .working))
        await link.look()
        let long = String(repeating: "a", count: 5000)
        await w.receivers.setTurn(.init(turnID: "t1", state: .done(answer: long)))
        await link.look(); await link.look()
        await link.flushed()
        let sent = await w.wa.sent
        #expect(sent.allSatisfy { $0.to == Self.him })
        #expect(sent.count == 2 && sent.map(\.text).joined() == long)       // split at 4096, in order, once
        #expect(!sent.contains { $0.text.contains("an old answer") })
    }

    @Test func everyFinalAnswerGoesBackAlsoForAQuestionTypedOnTheMac() async throws {
        let w = WAWorld()
        let box = WARecordBox(.init(id: "wa-1", name: "Phone", receiver: .session(id: "s1", name: "CRM"), readerID: "a", creator: Self.him, offset: 5, addedAt: 0))
        await w.receivers.open(.init(sessionID: "s1", isTerminal: false))
        await w.receivers.setTurn(.init(turnID: "t0", state: .idle))
        let link = w.link(box)
        await link.look()                                           // seeds: nothing old is sent
        await w.receivers.setTurn(.init(turnID: "t-mac", state: .done(answer: "Built.")))
        await link.look(); await link.flushed()
        #expect(await w.wa.sent.map(\.text) == ["Built."])
    }

    @Test func anApprovalIsAskedOnceAndAnsweredWithOneOrTwo() async throws {
        let w = WAWorld()
        let box = WARecordBox(.init(id: "wa-1", name: "Phone", receiver: .hoot, readerID: "a", creator: Self.him, offset: 5, addedAt: 0))
        let link = w.link(box)
        await w.receivers.setTurn(.init(turnID: "t0", state: .idle))
        await link.take(w.text("m1", "deploy it"))
        await w.receivers.setTurn(.init(turnID: "t1", state: .needsApproval([.init(id: "r1", summary: "It asks to use Bash.", detail: "./deploy.sh prod")])))
        await link.look(); await link.look(); await link.flushed()
        let asked = await w.wa.sent.map(\.text)
        #expect(asked.count == 1 && asked[0].contains("./deploy.sh prod") && asked[0].hasSuffix("Reply 1 to allow, 2 to deny."))
        await link.take(w.text("m2", " 1 "))
        #expect(await w.receivers.approvals == [.init(id: "r1", allow: true)])
        #expect(await w.receivers.said.map(\.text) == ["deploy it"])         // "1" is not a message
        // Anything else is a normal message and the question stays open in Terminal Deck.
        await w.receivers.setTurn(.init(turnID: "t1", state: .needsApproval([.init(id: "r2", summary: "Write a file.", detail: "a.txt")])))
        await link.look()
        await link.take(w.text("m3", "what does it do?"))
        #expect(await w.receivers.said.map(\.text).last == "what does it do?")
        #expect(BackendWhatsAppLink.approvalAnswer("deny") == false && BackendWhatsAppLink.approvalAnswer("Allow") == true && BackendWhatsAppLink.approvalAnswer("ok") == nil)
    }

    @Test func oneQuestionAtATimeAndAOneWrittenBeforeTheQuestionIsNotAnAnswer() async throws {
        let w = WAWorld()
        let box = WARecordBox(.init(id: "wa-1", name: "Phone", receiver: .hoot, readerID: "a", creator: Self.him, offset: 5, addedAt: 0))
        let link = w.link(box)
        await w.receivers.setTurn(.init(turnID: "t0", state: .idle))
        await link.take(w.text("m1", "deploy and clean up"))
        let early = w.text("m-early", "1", ago: 30)                        // written before any question was asked
        await w.receivers.setTurn(.init(turnID: "t1", state: .needsApproval([.init(id: "r1", summary: "Deploy.", detail: "./deploy.sh"),
                                                                             .init(id: "r2", summary: "Delete.", detail: "rm -rf build")])))
        await link.look(); await link.look(); await link.flushed()
        do { let sent = await w.wa.sent; #expect(sent.count == 1 && sent[0].text.contains("./deploy.sh")) }   // only the first
        await link.take(early)
        #expect(await w.receivers.approvals.isEmpty)                        // too old: a normal message
        await link.take(w.text("m2", "1"))
        #expect(await w.receivers.approvals == [.init(id: "r1", allow: true)])
        await w.receivers.setTurn(.init(turnID: "t1", state: .needsApproval([.init(id: "r2", summary: "Delete.", detail: "rm -rf build")])))
        await link.look(); await link.flushed()
        do { let sent2 = await w.wa.sent; #expect(sent2.count == 2 && sent2[1].text.contains("rm -rf build")) }   // the second, after the first
    }

    @Test func aPictureOrDocumentToATerminalIsNeverTyped() async throws {
        let w = WAWorld()
        let box = WARecordBox(.init(id: "wa-1", name: "Phone", receiver: .session(id: "t1", name: "Shell"), readerID: "a", creator: Self.him, offset: 5, addedAt: 0))
        await w.receivers.open(.init(sessionID: "t1", isTerminal: true))
        await w.wa.setMedia("doc", .init(data: Data("rm -rf ~\n".utf8), mimeType: "text/plain", fileName: "x.sh"))
        let link = w.link(box)
        await link.take(.init(id: "m1", from: Self.him, timestamp: w.clock.date(), kind: .document, caption: "run this", mediaID: "doc", mimeType: "text/plain", fileName: "x.sh"))
        await link.flushed()
        #expect(await w.receivers.typed.isEmpty)
        #expect(await w.wa.sent.map(\.text) == ["A terminal takes text only here."])
    }

    @Test func aRedirectCarriesTheKeyOnlyToWhatsAppsAndMetasOwnHosts() {
        let hosts = WhatsAppHTTPTransport.defaultMediaHosts
        #expect(WhatsAppRedirectGuard.allowed(URL(string: "https://lookaside.fbsbx.com/media/1"), hosts: hosts))
        #expect(WhatsAppRedirectGuard.allowed(URL(string: "https://api.whatsapp.com/agent/v1/x"), hosts: hosts))
        #expect(!WhatsAppRedirectGuard.allowed(URL(string: "https://evil.example/collect"), hosts: hosts))
        #expect(!WhatsAppRedirectGuard.allowed(URL(string: "http://lookaside.fbsbx.com/media/1"), hosts: hosts))
        #expect(!WhatsAppRedirectGuard.allowed(URL(string: "https://whatsapp.com.evil.example/"), hosts: hosts))
    }

    @Test func voiceVideoAndStickerGetTheOnePlainLineAndAReactionIsIgnored() async throws {
        let w = WAWorld()
        let box = WARecordBox(.init(id: "wa-1", name: "Phone", receiver: .hoot, readerID: "a", creator: Self.him, offset: 5, addedAt: 0))
        let link = w.link(box)
        for (id, kind) in [("v", WhatsAppInbound.Kind.audio), ("x", .video), ("s", .sticker), ("r", .reaction)] {
            await link.take(.init(id: id, from: Self.him, timestamp: w.clock.date(), kind: kind, mediaID: "media-" + id))
        }
        await link.flushed()
        #expect(await w.wa.sent.map(\.text) == Array(repeating: "I read text, pictures and documents here.", count: 3))
        #expect(await w.receivers.said.isEmpty)
    }

    @Test func aMessageOlderThanADayIsMarkedReadAndAnsweredWithTheLateLine() async throws {
        let w = WAWorld()
        let box = WARecordBox(.init(id: "wa-1", name: "Phone", receiver: .hoot, readerID: "a", creator: Self.him, offset: 5, addedAt: 0))
        let link = w.link(box)
        await link.take(w.text("old", "are you there?", ago: 25 * 3600))
        await link.flushed()
        #expect(await w.wa.sent.map(\.text) == ["This reached me late; send it again if you still need it."])
        #expect(await w.wa.reads.contains { $0.id == "old" && !$0.typing })
        #expect(await w.receivers.said.isEmpty)
    }

    @Test func aPictureArrivesAsAnAttachmentAndAnOtherDocumentKindIsSaidPlainly() async throws {
        let w = WAWorld()
        let box = WARecordBox(.init(id: "wa-1", name: "Phone", receiver: .hoot, readerID: "a", creator: Self.him, offset: 5, addedAt: 0))
        let link = w.link(box)
        await w.wa.setMedia("pic", .init(data: Data([0x89, 0x50, 0x4e, 0x47]), mimeType: "image/png"))
        await link.take(.init(id: "m1", from: Self.him, timestamp: w.clock.date(), kind: .image, caption: "this screen", mediaID: "pic", mimeType: "image/png"))
        let said = try #require(await w.receivers.said.first)
        #expect(said.text == "this screen" && said.attachments.first?.mimeType == "image/png")
        await w.wa.setMedia("doc", .init(data: Data([1, 2]), mimeType: "application/zip", fileName: "a.zip"))
        await link.take(.init(id: "m2", from: Self.him, timestamp: w.clock.date(), kind: .document, mediaID: "doc", mimeType: "application/zip"))
        await link.flushed()
        #expect(await w.wa.sent.map(\.text) == ["I read pictures, PDF and text documents here."])
    }

    @Test func onlyTheCreatorIsEverWrittenTo() async throws {
        let w = WAWorld()
        let box = WARecordBox(.init(id: "wa-1", name: "Phone", receiver: .hoot, readerID: "a", creator: Self.him, offset: 5, addedAt: 0))
        let link = w.link(box)
        await link.take(.init(id: "x", from: "user:someone-else", timestamp: w.clock.date(), kind: .text, text: "hi"))
        await link.flushed()
        do { let sent = await w.wa.sent, said = await w.receivers.said; #expect(sent.isEmpty && said.isEmpty) }
    }

    // MARK: The switch

    @Test func withTheSwitchOffNothingIsSentAndAMessageFromWhatsAppTurnsItOn() async throws {
        let w = WAWorld()
        let box = WARecordBox(.init(id: "wa-1", name: "Phone", receiver: .session(id: "s1", name: "CRM"), readerID: "a", creator: Self.him, offset: 5, addedAt: 0, sending: false))
        await w.receivers.open(.init(sessionID: "s1", isTerminal: false))
        await w.receivers.setTurn(.init(turnID: "t0", state: .idle))
        let link = w.link(box)
        await link.look()
        await w.receivers.setTurn(.init(turnID: "t1", state: .needsApproval([.init(id: "r1", summary: "Run it.", detail: "make")])))
        await link.look()
        await w.receivers.setTurn(.init(turnID: "t1", state: .done(answer: "Done on the Mac.")))
        await link.look(); await link.flushed()
        #expect(await w.wa.sent.isEmpty)                                    // off: no answer, no approval
        await link.take(w.text("m1", "and now?"))
        #expect(await box.record.isSending)                                 // his WhatsApp message turned it on
        await w.receivers.setTurn(.init(turnID: "t2", state: .done(answer: "Now on WhatsApp.")))
        await link.look(); await link.flushed()
        #expect(await w.wa.sent.map(\.text) == ["Now on WhatsApp."])
    }

    @Test func attachingTurnsTheSwitchOnAndTheSwitchIsSynced() async throws {
        let w = WAWorld()
        let a = w.engine(w.macA), b = w.engine(w.macB)
        let added = try await a.add(name: "Phone", key: Self.keyA)
        try await a.setSending(false, for: added.id)
        #expect(await b.agents().first?.sending == false)                   // the other computer reads the same setting
        try await a.setReceiver(added.id, .session(id: "s1", name: "CRM"))
        #expect(await b.agents().first?.sending == true)
        await a.stop(); await b.stop()
    }

    // MARK: Sessions and terminals

    @Test func anEndedSessionGoesNowhereAndTheNextMessageIsAnsweredOnce() async throws {
        let w = WAWorld()
        let box = WARecordBox(.init(id: "wa-1", name: "Phone", receiver: .session(id: "s1", name: "CRM"), readerID: "a", creator: Self.him, offset: 5, addedAt: 0))
        await w.receivers.open(.init(sessionID: "s1", isTerminal: false))
        let link = w.link(box)
        await link.look()
        await w.receivers.close("s1")
        await link.look()
        do { let record = await box.record; #expect(record.receiver == .nowhere && record.endedSession) }
        await link.take(w.text("m1", "status?"))
        await link.take(w.text("m2", "status??"))
        await link.flushed()
        let sent = await w.wa.sent.map(\.text)
        #expect(sent.first == "That session has ended. Choose where I should answer in Terminal Deck.")
        #expect(sent.filter { $0.contains("session has ended") }.count == 1)
    }

    @Test func aTerminalSessionTakesTheTextAsTypedInputAndSendsBackWhatItPrinted() async throws {
        let w = WAWorld()
        let box = WARecordBox(.init(id: "wa-1", name: "Phone", receiver: .session(id: "t1", name: "Shell"), readerID: "a", creator: Self.him, offset: 5, addedAt: 0))
        await w.receivers.open(.init(sessionID: "t1", isTerminal: true))
        await w.receivers.setScreens(["$ ", "$ ls\nREADME.md\nsrc\n$ "])
        let link = w.link(box)
        await link.take(w.text("m1", "ls"))
        await link.flushed()
        #expect(await w.receivers.typed == ["ls\r"])
        let sent = try #require(await w.wa.sent.first?.text)
        #expect(sent == "```\nREADME.md\nsrc\n```")
        #expect(BackendWhatsAppLink.newLines(before: "a\n", after: "a\n" + (1...60).map(String.init).joined(separator: "\n")).split(separator: "\n").count == 40)
    }

    // MARK: One reader per agent across computers

    @Test func onlyTheComputerWhereItWasAttachedReadsIt() async throws {
        let w = WAWorld()
        let a = w.engine(w.macA), b = w.engine(w.macB)
        let added = try await a.add(name: "Phone", key: Self.keyA)
        await a.reconcile(); await b.reconcile()
        do { let hereA = await a.readHere(), hereB = await b.readHere(); #expect(hereA == [added.id] && hereB.isEmpty) }
        #expect(await b.agents().first?.answeredElsewhereWords == "Answered by Mac A")
        // Moving the receiver moves the reader.
        try await b.setReceiver(added.id, .hoot)
        await a.reconcile(); await b.reconcile()
        do { let hereA2 = await a.readHere(), hereB2 = await b.readHere(); #expect(hereA2.isEmpty && hereB2 == [added.id]) }
        await a.stop(); await b.stop()
    }

    @Test func twoAgentsWithDifferentReceiversAreReadByTheirOwnComputers() async throws {
        let w = WAWorld()
        let a = w.engine(w.macA), b = w.engine(w.macB)
        let one = try await a.add(name: "Work", key: Self.keyA)
        let two = try await b.add(name: "Home", key: Self.keyB)
        try await b.setReceiver(two.id, .session(id: "s9", name: "Notes"))
        await a.reconcile(); await b.reconcile()
        do { let hereA3 = await a.readHere(), hereB3 = await b.readHere(); #expect(hereA3 == [one.id] && hereB3 == [two.id]) }
        await a.stop(); await b.stop()
    }

    @Test func aHootReceiverIsTakenOverAfterTenMinutesButASessionNever() async throws {
        let w = WAWorld()
        let a = w.engine(w.macA), b = w.engine(w.macB)
        let hoot = try await a.add(name: "Phone", key: Self.keyA)
        let session = try await a.add(name: "Build", key: Self.keyB)
        try await a.setReceiver(session.id, .session(id: "s1", name: "CRM"))
        await a.stop()
        await w.seen.set("a", w.clock.date().addingTimeInterval(-9 * 60))
        await b.reconcile()
        #expect(await b.readHere().isEmpty)                                 // 9 minutes: not yet
        await w.seen.set("a", w.clock.date().addingTimeInterval(-11 * 60))
        await b.reconcile()
        #expect(await b.readHere() == [hoot.id])                            // Hoot moves; the session does not
        let row = try #require(await b.agents().first { $0.id == hoot.id })
        #expect(row.answeredHere && row.takenOver)
        await b.stop()
    }

    @Test func a409WhileStillTheReaderPollsAgainAndAnotherNamedReaderStopsIt() async throws {
        let w = WAWorld()
        let a = w.engine(w.macA)
        let added = try await a.add(name: "Phone", key: Self.keyA)
        try await w.settings.edit(added.id) { $0.offset = 7; $0.creator = Self.him }
        await w.wa.queue([.replaced])
        let before = await w.wa.pollCount
        try await w.until { await w.wa.pollCount > before + 3 }            // review fault 2: it polls again, never held forever
        #expect(await a.readHere() == [added.id])
        try await w.settings.edit(added.id) { $0.readerID = "b"; $0.readerName = "Mac B" }
        await w.wa.queue([.replaced])
        try await w.until { await a.readHere().isEmpty }                   // the record names B: this one stops
        await a.stop()
    }

    @Test func aBatchIsNotAnsweredOnceTheRecordNamesAnotherComputer() async throws {
        let w = WAWorld()
        let box = WARecordBox(.init(id: "wa-1", name: "Phone", receiver: .hoot, readerID: "b", creator: Self.him, offset: 5, addedAt: 0))
        let stops = WAStops()
        let link = BackendWhatsAppLink(agentID: "wa-1", key: Self.keyA, transport: w.wa, receivers: w.receivers, clock: w.clock.link,
            read: { await box.record }, update: { change in await box.edit(change) }, stopped: { why in await stops.add(why) },
            stillReader: { await box.record.readerID == "a" })
        await w.wa.queue([.messages([w.text("m1", "run the deploy")], next: 6)])
        await link.start()
        try await w.until { await stops.list.count == 1 }
        do { let said = await w.receivers.said, sent = await w.wa.sent; #expect(said.isEmpty && sent.isEmpty) }
        #expect(await box.record.offset == 5)
        await link.stop()
    }

    @Test func aReplacedKeyIsReadOnlyWithTheNewKeyAndStartsFresh() async throws {
        let w = WAWorld()
        let keysA = WhatsAppKeysInMemory(), keysB = WhatsAppKeysInMemory()
        let a = w.engine(w.macA, keys: keysA), b = w.engine(w.macB, keys: keysB)
        let added = try await a.add(name: "Phone", key: Self.keyA)
        try await w.settings.edit(added.id) { $0.offset = 7; $0.creator = Self.him }
        try await keysB.setKey(Self.keyA, for: added.id)
        #expect(await a.link(added.id)?.keyID == WhatsAppAgentIDs.fingerprint(Self.keyA))
        try await b.replaceKey(added.id, key: Self.keyB)                  // pressed on the other Mac
        let record = try #require(await w.settings.records().first)
        #expect(record.keyID == WhatsAppAgentIDs.fingerprint(Self.keyB) && record.creator == nil && record.offset == nil)
        #expect(!String(decoding: try JSONEncoder().encode(record), as: UTF8.self).contains(Self.keyB))
        await a.reconcile()
        #expect(await a.readHere().isEmpty)                                 // the new key has not arrived here: not read
        try await keysA.setKey(Self.keyB, for: added.id)                    // it arrives through saved passwords
        await a.reconcile()
        #expect(await a.link(added.id)?.keyID == WhatsAppAgentIDs.fingerprint(Self.keyB))
        await a.stop(); await b.stop()
    }

    @Test func aRefusedKeyWhileReadingTurnsTheRowOrangeUntilANewKey() async throws {
        let w = WAWorld()
        let a = w.engine(w.macA)
        let added = try await a.add(name: "Phone", key: Self.keyA)
        try await w.settings.edit(added.id) { $0.offset = 7 }
        await w.wa.queue([.keyRefused])
        await a.reconcile()
        try await w.until { await a.agents().first?.state == .refused }
        await #expect(throws: WhatsAppProblem.keyRefused) { try await a.replaceKey(added.id, key: Self.refused) }
        try await a.replaceKey(added.id, key: Self.keyB)
        #expect(await a.agents().first?.state == .waiting)
        #expect(try await w.keys.key(added.id) == Self.keyB)
        await a.stop()
    }

    @Test func sendsGoOneAfterAnotherInOrder() async throws {
        let w = WAWorld()
        let box = WARecordBox(.init(id: "wa-1", name: "Phone", receiver: .hoot, readerID: "a", creator: Self.him, offset: 5, addedAt: 0))
        let link = w.link(box)
        await w.wa.setSlow(true)
        for n in 1...5 { await link.send("piece \(n)", to: Self.him, format: false) }
        await link.flushed()
        #expect(await w.wa.sent.map(\.text) == (1...5).map { "piece \($0)" })
        #expect(await w.wa.mostAtOnce == 1)
    }

    // MARK: A session that moves takes its WhatsApp agent with it (design section 5)

    /// Mac A runs "CRM" (local id s1, Cloud id c1) with a WhatsApp agent attached; Mac B has its own sessions.
    func movedWorld() async throws -> (w: WAWorld, a: BackendWhatsAppAgents, b: BackendWhatsAppAgents, onB: FakeReceivers, id: String) {
        let w = WAWorld(), onB = FakeReceivers()
        let a = w.engine(w.macA), b = w.engine(w.macB, receivers: onB)
        let added = try await a.add(name: "Phone", key: Self.keyA)
        await w.receivers.open(.init(sessionID: "s1", isTerminal: false))
        await w.receivers.setCloud("s1", "c1")
        try await a.setReceiver(added.id, .session(id: "s1", name: "CRM"))
        try await w.until { await w.settings.records().first?.offset != nil }
        try await Task.sleep(nanoseconds: 20_000_000)
        try await w.settings.edit(added.id) { $0.offset = 7; $0.creator = Self.him }
        // A looks while CRM is open (a look before his first message sees no creator and keeps no session), as the
        // running link's own watch does within 2 s in the app; without it a close right after would find nothing to end.
        await a.link(added.id)?.look()
        await b.reconcile()
        do { let hereA = await a.readHere(), hereB = await b.readHere(); #expect(hereA == [added.id] && hereB.isEmpty) }
        #expect(await w.settings.records().first?.cloudSessionID == "c1")
        return (w, a, b, onB, added.id)
    }

    @Test func aMovedSessionsAgentIsReadAndAnsweredOnTheNewComputerAndTheSwitchIsKept() async throws {
        let (w, a, b, onB, id) = try await movedWorld()
        try await a.setSending(false, for: id)
        // Old Mac: the move starts and the session closes the app's way. Not "ended".
        await w.receivers.setLeaving("c1", true)
        await w.receivers.close("s1")
        await a.link(id)?.look()
        var record = try #require(await w.settings.records().first)
        #expect(record.receiver == .session(id: "s1", name: "CRM") && !record.endedSession && record.readerID == "a")
        // New Mac: its take succeeded; the session runs there as s2. Nothing asked.
        await onB.open(.init(sessionID: "s2", isTerminal: false))
        await b.sessionArrived(cloudSessionID: "c1", sessionID: "s2")
        record = try #require(await w.settings.records().first)
        #expect(record.receiver == .session(id: "s2", name: "CRM") && record.readerID == "b" && record.readerName == "Mac B" && !record.takenOver)
        #expect(record.offset == 7 && record.creator == Self.him && record.keyID == WhatsAppAgentIDs.fingerprint(Self.keyA))
        #expect(record.sending == false && record.cloudSessionID == "c1")    // the switch keeps its position
        await a.reconcile()
        do { let hereA = await a.readHere(), hereB = await b.readHere(); #expect(hereA.isEmpty && hereB == [id]) }           // the old one stops: the record names B
        #expect(await b.agents().first?.answeredHere == true)
        await w.wa.queue([.messages([w.text("m1", "status?")], next: 8)])
        try await w.until { await onB.said.count == 1 }
        await onB.setTurn(.init(turnID: "t1", state: .done(answer: "All green.")))
        try await w.until { await w.wa.sent.map(\.text).contains("All green.") }
        let told = await w.wa.sent.map(\.text)
        #expect(!told.contains { $0.contains("session has ended") || $0.contains("not received anywhere") })
        #expect(await w.receivers.said.isEmpty)
        await a.stop(); await b.stop()
    }

    @Test func aMessageThatArrivesDuringTheMoveIsAnsweredOnceByTheNewComputer() async throws {
        let (w, a, b, onB, id) = try await movedWorld()
        await w.receivers.setLeaving("c1", true)                             // the old Mac is handing it over
        try await Task.sleep(nanoseconds: 30_000_000)
        let settled = await w.wa.pollCount
        await w.wa.queue([.messages([w.text("m1", "deploy now")], next: 8)])
        try await Task.sleep(nanoseconds: 30_000_000)
        do { let polls = await w.wa.pollCount, queued = await w.wa.queued; #expect(polls == settled && queued == 1) }          // the old Mac does not poll it
        await w.receivers.close("s1")
        await onB.open(.init(sessionID: "s2", isTerminal: false))
        await b.sessionArrived(cloudSessionID: "c1", sessionID: "s2")
        await a.reconcile()
        try await w.until { await w.settings.records().first?.offset == 8 }
        do { let saidB = await onB.said, saidHere = await w.receivers.said; #expect(saidB.map(\.text) == ["deploy now"] && saidHere.isEmpty) }
        #expect(await w.wa.offsets.dropFirst(settled).first == 7)             // read from the kept position
        let told = await w.wa.sent.map(\.text)
        #expect(!told.contains { $0.contains("session has ended") })
        await a.stop(); await b.stop()
    }

    @Test func aBatchOnItsWayAsTheMoveStartsIsNotTakenAndThePositionStays() async throws {
        let w = WAWorld()
        let box = WARecordBox(.init(id: "wa-1", name: "Phone", receiver: .session(id: "s1", name: "CRM"), readerID: "a", creator: Self.him, offset: 5, addedAt: 0))
        await w.receivers.open(.init(sessionID: "s1", isTerminal: false))
        let asked = WACount()
        // Not moving when the poll starts; moving by the time its batch arrives.
        let link = BackendWhatsAppLink(agentID: "wa-1", key: Self.keyA, transport: w.wa, receivers: w.receivers, clock: w.clock.link,
            read: { await box.record }, update: { change in await box.edit(change) }, stopped: { _ in },
            holding: { await asked.next() > 1 })
        await w.wa.queue([.messages([w.text("m1", "run the deploy")], next: 6)])
        await link.start()
        try await w.until { await asked.n > 3 }
        await link.stop()
        do { let said = await w.receivers.said, sent = await w.wa.sent; #expect(said.isEmpty && sent.isEmpty) }
        #expect(await box.record.offset == 5)                                  // given again to the computer that takes it
    }

    @Test func aSlowBatchOnTheOldComputerNeverUndoesTheNewComputersClaim() async throws {
        let (w, a, b, onB, id) = try await movedWorld()
        await w.receivers.setHoldSay(true)
        await w.wa.queue([.messages([w.text("m1", "build it")], next: 8)])
        try await w.until { await w.receivers.saying }                     // the old Mac is inside the batch
        await w.receivers.setLeaving("c1", true)                           // the move starts meanwhile
        await w.receivers.close("s1")
        await onB.open(.init(sessionID: "s2", isTerminal: false))
        await b.sessionArrived(cloudSessionID: "c1", sessionID: "s2")
        await w.receivers.setHoldSay(false)                                // the old batch finishes and tries to save
        try await w.until { await w.receivers.said.count == 1 }
        try await Task.sleep(nanoseconds: 30_000_000)
        let record = try #require(await w.settings.records().first)
        #expect(record.receiver == .session(id: "s2", name: "CRM") && record.readerID == "b" && record.offset == 7)
        await a.reconcile()
        do { let hereA = await a.readHere(), hereB = await b.readHere(); #expect(hereA.isEmpty && hereB == [id]) }
        await w.wa.queue([.messages([w.text("m2", "and test it")], next: 9)])   // the new Mac keeps reading
        try await w.until { await onB.said.map(\.text) == ["and test it"] }
        try await w.until { await w.settings.records().first?.offset == 9 }
        #expect(await w.settings.records().first?.readerID == "b")
        await a.stop(); await b.stop()
    }

    @Test func aMoveThatIsCalledOffLeavesTheAgentWhereItWas() async throws {
        let (w, a, b, onB, id) = try await movedWorld()
        let before = try #require(await w.settings.records().first)
        await w.receivers.setLeaving("c1", true)
        await a.link(id)?.look()
        try await Task.sleep(nanoseconds: 20_000_000)
        await w.receivers.setLeaving("c1", false)                            // cancelled: the session runs on here
        #expect(try #require(await w.settings.records().first) == before)
        await w.wa.queue([.messages([w.text("m1", "still there?")], next: 8)])
        try await w.until { await w.receivers.said.count == 1 }
        do { let saidB = await onB.said, hereB = await b.readHere(), hereA = await a.readHere(); #expect(saidB.isEmpty && hereB.isEmpty && hereA == [id]) }
        try await w.until { await w.settings.records().first?.offset == 8 }
        let after = try #require(await w.settings.records().first)
        #expect(after.receiver == .session(id: "s1", name: "CRM") && after.readerID == "a" && !after.endedSession && after.isSending)
        await a.stop(); await b.stop()
    }

    @Test func aSessionThatReallyEndsStillGoesNowhereWithTheOneEndedLine() async throws {
        let (w, a, b, _, id) = try await movedWorld()
        await w.receivers.setLeaving("c9", true)                             // another session moving changes nothing here
        await w.receivers.close("s1")
        // The running link's own watch also looks: whichever look sees the close first writes Nowhere (the other returns
        // early meanwhile), so the write is waited for, never read straight after one look.
        await a.link(id)?.look()
        try await w.until {
            guard let record = await w.settings.records().first else { return false }
            return record.receiver == .nowhere && record.endedSession
        }
        // Design section 4: the NEXT message is answered once with the ended line; then the agent is at Nowhere and
        // no computer reads it, so a later message is kept in WhatsApp, not answered.
        await w.wa.queue([.messages([w.text("m1", "status?")], next: 9)])
        try await w.until { await w.settings.records().first?.offset == 9 }
        await a.reconcile()                                                  // the settings change ends the reading
        let hereA = await a.readHere(), hereB = await b.readHere()
        #expect(hereA.isEmpty && hereB.isEmpty)
        await w.wa.queue([.messages([w.text("m2", "status??")], next: 10)])
        try await Task.sleep(nanoseconds: 30_000_000)
        await a.stop(); await b.stop()
        let sent = await w.wa.sent.map(\.text), queued = await w.wa.queued
        #expect(sent == [BackendWhatsAppLink.Words.ended] && queued == 1)
    }

    // MARK: The store "whatsapp" (keys travel)

    @Test func aKeyTravelsIsOneItemWhenTheSameAndHisStaysWhenDifferent() async throws {
        let f = try WAKeysFixture(); defer { f.close() }
        let keysA = WhatsAppKeysInMemory(["wa-aaaa": Self.keyA]), keysB = WhatsAppKeysInMemory()
        let a = await f.wrap(BackendWhatsAppKeysStore(keeper: keysA, names: { _ in "Phone" }).deleteRuleStore(stateRoot: f.state("A"), gate: { true }, now: f.now), "A")
        let b = await f.wrap(BackendWhatsAppKeysStore(keeper: keysB).deleteRuleStore(stateRoot: f.state("B"), gate: { true }, now: f.now), "B")
        let record = try #require(try await a.capture().first)
        #expect(try await b.merge(record) == .applied)
        #expect(try await keysB.key("wa-aaaa") == Self.keyA)
        #expect(try await b.merge(record) == .alreadyPresent)
        let other = WhatsAppKeysInMemory(["wa-aaaa": Self.keyB])
        let c = await f.wrap(BackendWhatsAppKeysStore(keeper: other).deleteRuleStore(stateRoot: f.state("C"), gate: { true }, now: f.now), "C")
        #expect(try await c.merge(record) == .keptBoth)
        #expect(try await other.key("wa-aaaa") == Self.keyB)                // never overwritten
    }

    @Test func aKeyReplacedOnOneComputerReplacesTheUnchangedOneOnTheOther() async throws {
        let f = try WAKeysFixture(); defer { f.close() }
        let keysA = WhatsAppKeysInMemory(["wa-aaaa": Self.keyA]), keysB = WhatsAppKeysInMemory()
        let a = await f.wrap(BackendWhatsAppKeysStore(keeper: keysA).deleteRuleStore(stateRoot: f.state("A"), gate: { true }, now: f.now), "A")
        let b = await f.wrap(BackendWhatsAppKeysStore(keeper: keysB).deleteRuleStore(stateRoot: f.state("B"), gate: { true }, now: f.now), "B")
        for record in try await a.capture() { _ = try await b.merge(record) }
        _ = try await b.capture()
        try await keysA.setKey(Self.keyB, for: "wa-aaaa")
        let changed = try #require(try await a.capture().first)
        #expect(try await b.merge(changed) == .applied)
        #expect(try await keysB.key("wa-aaaa") == Self.keyB)
    }

    @Test func aKeyRemovedInTheAppIsRemovedEverywhere() async throws {
        let f = try WAKeysFixture(); defer { f.close() }
        let keysA = WhatsAppKeysInMemory(["wa-aaaa": Self.keyA]), keysB = WhatsAppKeysInMemory()
        let a = await f.wrap(BackendWhatsAppKeysStore(keeper: keysA, names: { _ in "Phone" }).deleteRuleStore(stateRoot: f.state("A"), gate: { true }, now: f.now), "A")
        let b = await f.wrap(BackendWhatsAppKeysStore(keeper: keysB).deleteRuleStore(stateRoot: f.state("B"), gate: { true }, now: f.now), "B")
        for record in try await a.capture() { _ = try await b.merge(record) }
        _ = try await b.capture()
        let item = try #require(await a.items().first)
        #expect(item.name == "WhatsApp · Phone" && !item.name.contains(Self.keyA))
        _ = try await a.deleteItems([item], scope: .everywhere, by: f.actor())
        #expect(try await b.mergeRemoval(#require(await a.captureRemovals().first)) == .applied)
        #expect(try await keysB.key("wa-aaaa") == nil)
    }

    @Test func aKeeperThatIsNotReadySaysLockedNeverEmpty() async throws {
        let keys = WhatsAppKeysInMemory(["wa-aaaa": Self.keyA], ready: false)
        let store = BackendWhatsAppKeysStore(keeper: keys)
        await #expect(throws: CloudFailure.secretsLocked) { _ = try await store.capture() }
        #expect(BackendCloudSecretsLean.sources[BackendWhatsAppKeysStore.source] == .whatsapp)
        #expect(BackendCloudSecretsLeanCoverage.order.contains(BackendWhatsAppKeysStore.source))
        let line = try #require(BackendCloudShelfSealed.password(try BackendCloudSecretsRecords.record("whatsapp", "wa-aaaa", .whatsapp, WhatsAppKeyValue(key: Self.keyA, name: "Phone"))))
        #expect(line.name == "WhatsApp · Phone" && line.fields.allSatisfy { $0.label != "Key" || $0.secret })
    }

    @Test func theToolsAreSuppliedWholeAndAskWhereTheyShould() {
        #expect(BackendWhatsAppTools.pageIDs.count == 8)
        let tiers = Dictionary(uniqueKeysWithValues: BackendWhatsAppTools.specs.map { ($0.id, $0.tier) })
        #expect(tiers[BackendWhatsAppTools.agentsID] == .read)
        for id in [BackendWhatsAppTools.addID, BackendWhatsAppTools.removeID, BackendWhatsAppTools.renameID, BackendWhatsAppTools.replaceKeyID] { #expect(tiers[id] == .alter) }
        for id in [BackendWhatsAppTools.receiveID, BackendWhatsAppTools.sendID, BackendWhatsAppTools.sendingID] { #expect(tiers[id] == .act) }
    }
}

// MARK: - Fakes

final class WAClock: @unchecked Sendable {
    private let lock = NSLock()
    private var at = Date(timeIntervalSince1970: 1_900_000_000)
    func date() -> Date { lock.withLock { at } }
    func advance(_ seconds: Double) { lock.withLock { at = at.addingTimeInterval(seconds) } }
    var link: BackendWhatsAppLink.Clock {
        .init(now: { self.date() }, sleep: { seconds in self.advance(seconds); try? await Task.sleep(nanoseconds: 1_000_000) })
    }
}

actor FakeWhatsApp: WhatsAppTransport {
    struct Sent: Equatable { let to: String, text: String }
    struct Read: Equatable { let id: String, typing: Bool }
    let accepted: Set<String>
    private var polls: [WhatsAppPoll] = []
    private(set) var sent: [Sent] = []
    private(set) var reads: [Read] = []
    private var media: [String: WhatsAppMedia] = [:]
    private var slow = false, sending = 0
    private(set) var mostAtOnce = 0
    init(accepted: Set<String>) { self.accepted = accepted }
    func queue(_ list: [WhatsAppPoll]) { polls += list }
    func setMedia(_ id: String, _ item: WhatsAppMedia) { media[id] = item }
    func setSlow(_ on: Bool) { slow = on }
    func check(key: String) -> WhatsAppKeyCheck { accepted.contains(key) ? .accepted : .refused }
    private(set) var pollCount = 0
    /// The position each poll started from (a held batch is given again from the same position).
    private(set) var offsets: [Int64?] = []
    var queued: Int { polls.count }
    func poll(key: String, offset: Int64?, timeout: Int) async -> WhatsAppPoll {
        // A cancelled reader must not consume the next scripted batch after its link has stopped.
        guard !Task.isCancelled else { return .nothing }
        pollCount += 1
        offsets.append(offset)
        if !polls.isEmpty { return polls.removeFirst() }
        try? await Task.sleep(nanoseconds: 2_000_000)
        return .nothing
    }
    func markRead(key: String, messageID: String, typing: Bool) -> WhatsAppSent { reads.append(.init(id: messageID, typing: typing)); return .sent }
    func send(key: String, to: String, text: String) async -> WhatsAppSent {
        sending += 1; mostAtOnce = max(mostAtOnce, sending)
        if slow { try? await Task.sleep(nanoseconds: 3_000_000) }
        sent.append(.init(to: to, text: text)); sending -= 1
        return .sent
    }
    func media(key: String, id: String, limit: Int) -> WhatsAppMedia? { media[id].flatMap { $0.data.count <= limit ? $0 : nil } }
}

actor FakeReceivers: WhatsAppReceiverPort {
    struct Said: Equatable { let text: String, attachments: [WhatsAppAttachment] }
    struct Answer: Equatable { let id: String, allow: Bool }
    private(set) var said: [Said] = []
    private(set) var approvals: [Answer] = []
    private(set) var typed: [String] = []
    private var current = WhatsAppTurn(turnID: nil, state: .idle)
    private var open: [String: WhatsAppTarget] = [:]
    private var screens: [String] = []
    func setTurn(_ turn: WhatsAppTurn) { current = turn }
    func open(_ target: WhatsAppTarget) { open[target.sessionID] = target }
    func close(_ id: String) { open[id] = nil }
    func setScreens(_ list: [String]) { screens = list }
    func target(for receiver: WhatsAppReceiver, conversationName: String, agentID: String) -> WhatsAppTarget? {
        switch receiver {
        case .nowhere: return nil
        case .hoot: return .init(sessionID: "hoot-" + agentID, isTerminal: false)
        case .agent(let id, _): return .init(sessionID: "agent-" + id, isTerminal: false)
        case .session(let id, _): return open[id]
        }
    }
    /// A slow receiver: `say` waits while held (`saying` true meanwhile).
    private var holdSay = false
    private(set) var saying = false
    func setHoldSay(_ on: Bool) { holdSay = on }
    func say(_ target: WhatsAppTarget, text: String, attachments: [WhatsAppAttachment]) async {
        saying = true
        while holdSay { try? await Task.sleep(nanoseconds: 1_000_000) }
        saying = false
        said.append(.init(text: text, attachments: attachments))
    }
    func turn(_ target: WhatsAppTarget) -> WhatsAppTurn? { current }
    func approve(_ target: WhatsAppTarget, approvalID: String, allow: Bool) -> Bool {
        guard case .needsApproval(let list) = current.state, list.contains(where: { $0.id == approvalID }) else { return false }
        approvals.append(.init(id: approvalID, allow: allow)); return true
    }
    func type(_ target: WhatsAppTarget, text: String) { typed.append(text) }
    func screen(_ target: WhatsAppTarget) -> String? {
        // Before anything is typed: the first screen; after: the last (what the command printed).
        typed.isEmpty ? screens.first : screens.last
    }
    func isOpen(_ target: WhatsAppTarget) -> Bool { target.sessionID.hasPrefix("hoot-") || target.sessionID.hasPrefix("agent-") || open[target.sessionID] != nil }
    func isToolSession(_ target: WhatsAppTarget, _ sessionID: String) -> Bool { false }
    /// Local session id -> its Cloud id; the Cloud ids this computer is giving away (the move's journal).
    private var clouds: [String: String] = [:]
    private var giving: Set<String> = []
    func setCloud(_ sessionID: String, _ cloud: String) { clouds[sessionID] = cloud }
    func setLeaving(_ cloud: String, _ on: Bool) { if on { giving.insert(cloud) } else { giving.remove(cloud) } }
    func cloudSessionID(_ sessionID: String) -> String? { clouds[sessionID] }
    func leaving(cloudSessionID: String) -> Bool { giving.contains(cloudSessionID) }
}

actor WASettings: WhatsAppSettingsPort {
    private var stored: [String: WhatsAppAgentRecord] = [:]
    private var observers: [@Sendable () -> Void] = []
    func records() -> [WhatsAppAgentRecord] { Array(stored.values) }
    func save(_ record: WhatsAppAgentRecord) {
        // Through JSON, as the synced setting is.
        stored[record.id] = try? JSONDecoder().decode(WhatsAppAgentRecord.self, from: JSONEncoder().encode(record))
        for observer in observers { observer() }
    }
    func observe(_ changed: @escaping @Sendable () -> Void) { observers.append(changed) }
    func edit(_ id: String, _ change: (inout WhatsAppAgentRecord) -> Void) throws {
        guard var record = stored[id] else { throw WhatsAppProblem.notFound }
        change(&record); stored[id] = record
    }
}

actor WASeen { var at: [String: Date] = [:]; func set(_ id: String, _ date: Date) { at[id] = date } }
struct WAPresence: WhatsAppPresencePort {
    let me: WhatsAppComputer
    let seen: WASeen
    func thisComputer() -> WhatsAppComputer { me }
    func lastSeen(_ computerID: String) async -> Date? { await seen.at[computerID] }
    func name(_ computerID: String) -> String? { ["a": "Mac A", "b": "Mac B"][computerID] }
}

actor WACount { var n = 0; func next() -> Int { n += 1; return n } }
actor WAStops { var list: [BackendWhatsAppLink.StopReason] = []; func add(_ why: BackendWhatsAppLink.StopReason) { list.append(why) } }

actor WARecordBox {
    var record: WhatsAppAgentRecord
    init(_ record: WhatsAppAgentRecord) { self.record = record }
    func edit(_ change: (inout WhatsAppAgentRecord) -> Void) { change(&record) }
}

struct WAWorld: Sendable {
    let clock = WAClock()
    let wa = FakeWhatsApp(accepted: Set([WhatsAppEngineTests.keyA, WhatsAppEngineTests.keyB] + (0..<7).map { "made-up-whatsapp-key-number-\($0)" }))
    let receivers = FakeReceivers()
    let settings = WASettings()
    let keys = WhatsAppKeysInMemory()
    let seen = WASeen()
    let macA = WhatsAppComputer(id: "a", name: "Mac A"), macB = WhatsAppComputer(id: "b", name: "Mac B")
    func engine(_ me: WhatsAppComputer, keys: WhatsAppKeysInMemory? = nil, receivers: FakeReceivers? = nil) -> BackendWhatsAppAgents {
        BackendWhatsAppAgents(transport: wa, settings: settings, keys: keys ?? self.keys, presence: WAPresence(me: me, seen: seen),
                              receivers: receivers ?? self.receivers, clock: clock.link)
    }
    func link(_ box: WARecordBox) -> BackendWhatsAppLink {
        BackendWhatsAppLink(agentID: "wa-1", key: WhatsAppEngineTests.keyA, transport: wa, receivers: receivers, clock: clock.link,
                            read: { await box.record }, update: { change in await box.edit(change) }, stopped: { _ in })
    }
    func text(_ id: String, _ body: String, ago: Double = 0) -> WhatsAppInbound {
        .init(id: id, from: WhatsAppEngineTests.him, timestamp: clock.date().addingTimeInterval(-ago), kind: .text, text: body)
    }
    /// Waits (real time, at most 2 s) for something the background loop does.
    func until(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<400 { if await condition() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        Issue.record("The condition was not reached in time.")
    }
}

/// The saved-passwords test frame (as CloudKeysTravelTests' own, which is private to that file).
struct WAKeysFixture: Sendable {
    let root: URL
    let shared = SymmetricKey(size: .bits256)
    let local = SymmetricKey(size: .bits256)
    let clock = WAClock()
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("td-whatsapp-keys-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func close() { try? FileManager.default.removeItem(at: root) }
    var now: @Sendable () -> Int64 { let clock = clock; return { Int64(clock.date().timeIntervalSince1970 * 1000) } }
    func state(_ mac: String) -> URL { root.appendingPathComponent(mac + "/state") }
    func actor() -> CloudDeleteActor {
        .init(by: .person, mac: "a", macName: "Mac A", session: nil, agent: nil, at: now(), group: UUID().uuidString)
    }
    func wrap(_ owner: BackendProjectSecretFilesSavedDeleteOwner, _ mac: String) async -> BackendProjectSecretFilesSavedDeleteOwner {
        await owner.use(keys: .init(epoch: 1, sharedKey: shared, local: local)); return owner
    }
}
