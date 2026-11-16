import Foundation
import Testing
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// PASSWORDS-5 (14 Nov): a passkey spare key must never be silently orphaned. Both Macs offered the passkey sheet at
/// start; the MacBook's sat open behind a locked screen after the Mac mini had made the spare. Answering it would have
/// made a second passkey for the same site and account (replacing the one the spare is sealed for) while the service
/// refuses a second spare. Fixture service, fixture passkeys, no Keychain, no network.
@Suite("Cloud saved passwords — the passkey sheet never orphans a spare")
@MainActor
struct CloudSecretsSpareSheetTests {
    private struct Mac {
        let client: CloudSecretsFixtureClient
        let graph: BackendCloudSecretsGraph
        let trust: AutoTrustBox
        let auto: CloudSecretsAutoTrust
        let lines: LogLines
    }
    private func graph(_ client: CloudSecretsFixtureClient, auto: CloudSecretsAutoTrust, passkey: (any CloudSecretsPasskeyPort)?,
                       lines: LogLines, wait: (@Sendable () async -> Void)? = nil) throws -> BackendCloudSecretsGraph {
        let made = try BackendCloudSecretsGraph(recovery: client.coordinator, content: client.content, policy: client.policy,
            local: client.local, deviceId: client.device.deviceId, outbox: AutoOutbox(), stores: [AutoLogins([:])],
            retainConflict: { _ in }, known: nil, restoreLocalStores: {}, turnsOnBySelf: true, startAgainAvailable: true,
            deadAfter: 0, automatic: auto, passkey: passkey, spareOfferWait: wait, log: lines.log,
            pause: { ms in if ms > 5_000 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } })
        return made
    }
    private func mac(_ server: CloudSecretsFixtureServer, passkey: (any CloudSecretsPasskeyPort)?) async throws -> Mac {
        let client = try await CloudSecretsFixtureClient(server: server)
        let box = AutoTrustBox(on: true), lines = LogLines()
        let auto = CloudSecretsAutoTrust(on: { box.isOn() }, pinned: { box.pinned($0) })
        await client.coordinator.use(automatic: auto)
        await client.coordinator.use(log: lines.log)
        let made = try graph(client, auto: auto, passkey: passkey, lines: lines)
        await made.guardPresses { false }
        return Mac(client: client, graph: made, trust: box, auto: auto, lines: lines)
    }
    private func notice(_ type: String) -> CloudEvent {
        CloudEvent(v: 1, type: type, id: UUID().uuidString.lowercased(), payload: CloudValue(.object([])))
    }
    /// `b` opens the saved passwords from `a` by itself (both trust each other), as on his two Macs.
    private func join(_ a: Mac, _ b: Mac, aName: String = "Mac mini", bName: String = "MacBook Pro") async {
        a.trust.trust(b.client.device, name: bName); b.trust.trust(a.client.device, name: aName)
        await b.graph.catchUp()
        await a.graph.event(notice("approval"))
        await b.graph.event(notice("vault"))
    }

    // Point 1: the spare appears while the sheet is open: the sheet is withdrawn, nothing is added, never offered again.
    @Test func aSpareMadeElsewhereWithdrawsTheOpenSheet() async throws {
        let server = CloudSecretsFixtureServer()
        await server.useServiceFacts()
        let a = try await mac(server, passkey: nil)
        await a.graph.catchUp()
        let held = FixturePasskey(server: server)
        await held.hold()
        let b = try await mac(server, passkey: held)
        await join(a, b)
        #expect(await b.client.local.value?.root == a.client.local.value?.root)
        // A later start of the MacBook: the sheet offers itself and stays open (locked screen).
        let offer = Task { await b.graph.catchUp() }
        await held.untilShown()
        // Meanwhile the Mac mini makes the spare.
        #expect(await a.client.coordinator.makeSpare(passkey: FixturePasskey(server: server)) == .added)
        await b.graph.event(notice("vault"))
        await offer.value
        #expect(await held.withdrawn == 1)
        #expect(await server.spares.count == 1)
        #expect(await server.spareAdded?.by == a.client.device.deviceId)
        #expect(b.lines.all.contains(CloudSecretsLog.prefix + "passkey spare key: sheet withdrawn: one was just made on Fixture Mac"))
        #expect(!b.lines.all.contains { $0.contains("add refused") || $0.contains("sheet cancelled") })
        // Withdrawn is not his cancel (no one-day hold) and the generation is never offered again.
        #expect(await b.client.local.book?.spareCancelledAt == nil)
        await b.client.coordinator.forgetThisRun()
        await held.hold(false)
        #expect(await b.client.coordinator.offerSpareOnce(passkey: held) == false)
        #expect(await held.sheets == 1)
        #expect(await b.graph.page().spareWarning == nil)
    }

    // Point 2: a fresh status with a spare on file shows no sheet, by itself or by his press.
    @Test func aSpareOnFileShowsNoSheetByItselfOrByHisPress() async throws {
        let server = CloudSecretsFixtureServer()
        await server.useServiceFacts()
        let first = FixturePasskey(server: server)
        let a = try await mac(server, passkey: first)
        await a.graph.catchUp()
        #expect(await server.spares.count == 1)
        let second = FixturePasskey(server: server)
        let b = try await mac(server, passkey: second)
        await join(a, b)
        await b.graph.catchUp()                       // the offer by itself
        await b.graph.perform(.makeSpare)             // his press
        #expect(await b.client.coordinator.makeSpare(passkey: second) == .notOffered)
        #expect(await second.sheets == 0)
        #expect(await server.spares.count == 1)
    }

    // Point 3: two Macs started together: the offer waits a random 5 to 40 seconds, then reads fresh; the first one
    // made wins and the other never shows its sheet.
    @Test func twoMacsStartingTogetherMakeOneSpareAndShowOneSheet() async throws {
        #expect(BackendCloudSecretsGraph.spareOfferWaitMs == 5_000...40_000)
        let server = CloudSecretsFixtureServer()
        await server.useServiceFacts()
        let a = try await mac(server, passkey: nil)
        await a.graph.catchUp()
        let b = try await mac(server, passkey: nil)
        await join(a, b)
        // Both updated together: a new run on each, with its passkey. The Mac mini's wait ends first.
        let pa = FixturePasskey(server: server), pb = FixturePasskey(server: server)
        let gate = SpareGate()
        let ga = try graph(a.client, auto: a.auto, passkey: pa, lines: a.lines, wait: {})
        let gb = try graph(b.client, auto: b.auto, passkey: pb, lines: b.lines, wait: { await gate.wait() })
        async let startB: Void = gb.catchUp()
        await ga.catchUp()
        await gate.open()
        await startB
        #expect(await pa.sheets + pb.sheets == 1)
        #expect(await pb.sheets == 0)
        #expect(await server.spares.count == 1)
        #expect(b.lines.all.contains { $0.hasPrefix(CloudSecretsLog.prefix + "passkey spare key: not offered: one is already on file, made on ") })
    }

    // Point 4: a sheet answered after the spare existed: the service refuses the add (409 spare_exists); the page and the
    // log say so, in words true in the race too, with the one repair control.
    @Test func aSecondPasskeyAfterTheSpareExistedIsSaidOnThePage() async throws {
        let server = CloudSecretsFixtureServer()
        await server.useServiceFacts()
        let a = try await mac(server, passkey: nil)
        await a.graph.catchUp()
        let held = FixturePasskey(server: server)
        await held.hold()
        let b = try await mac(server, passkey: held)
        await join(a, b)
        let offer = Task { await b.graph.catchUp() }
        await held.untilShown()
        #expect(await a.client.coordinator.makeSpare(passkey: FixturePasskey(server: server)) == .added)
        // No notice reaches the MacBook; he answers the old sheet.
        await held.answer()
        await offer.value
        #expect(await server.spares.count == 1)
        #expect(await server.spareAdded?.by == a.client.device.deviceId)
        let page = await b.graph.page()
        #expect(page.spareWarning == BackendCloudSecretsWords.spareOrphaned)
        #expect(page.spareWarning == "A second passkey was made on this Mac while another device was making your spare key. Your spare key may no longer open.")
        #expect(page.canRepairSpare && !page.canMakeSpare)
        #expect(b.lines.all.contains(CloudSecretsLog.prefix + "passkey spare key: add refused: a spare key is already on file for this key (spare_exists)"))
        #expect(b.lines.all.contains(CloudSecretsLog.prefix + "passkey spare key: a second passkey was made on this Mac while another device was making your spare key; your spare key may no longer open"))
        // The Mac mini, whose passkey made the spare, has no warning.
        #expect(await a.graph.page().spareWarning == nil)
    }

    // Point 1: a sheet whose one-time challenge ran out is withdrawn (an answer after that could never be added).
    @Test func aSheetWhoseRequestRanOutIsWithdrawn() async throws {
        let server = CloudSecretsFixtureServer()
        await server.useServiceFacts()
        let held = FixturePasskey(server: server)
        await held.hold()
        let a = try await mac(server, passkey: nil)
        await a.graph.catchUp()
        let gate = SpareGate()
        await a.client.coordinator.use(sleep: { _ in await gate.wait() })
        let offer = Task { await a.client.coordinator.makeSpare(passkey: held) }
        await held.untilShown()
        await gate.open()
        #expect(await offer.value == .notOffered)
        #expect(await held.withdrawn == 1)
        #expect(await server.spares.isEmpty)
        #expect(a.lines.all.contains(CloudSecretsLog.prefix + "passkey spare key: sheet withdrawn: its request ran out; it offers itself again at the next start"))
    }

    // Point 5: the spare's passkey is excluded when the service names it (status `spare.credentialId` once Servers adds
    // it; the challenge's `spares[]` today, which is empty whenever a sheet is shown at all).
    @Test func aNewPasskeyExcludesNothingWhenNoSpareIsOnFile() async throws {
        let server = CloudSecretsFixtureServer()
        await server.useServiceFacts()
        let passkey = FixturePasskey(server: server)
        let a = try await mac(server, passkey: passkey)
        await a.graph.catchUp()
        #expect(await passkey.sheets == 1)
        #expect(await passkey.excluded.isEmpty)
        let facts = BackendCloudSecretsControl.facts(try NativeRPCValue.parseJSON(Data(
            #"{"nobodyCanOpen":false,"spare":{"addedBy":"device-1","addedByName":"Mac mini","addedAt":7,"credentialId":"Y3JlZC0x"}}"#.utf8)))
        #expect(facts.spareCredentialId == "Y3JlZC0x")
    }

    // Points 6 and 8: friendly names from the account's list in the log and the read tool (never the host names), and
    // every device this Mac knows holds the key.
    @Test func devicesAreNamedByTheirFriendlyNamesAndEveryKnownHolderIsListed() async throws {
        let server = CloudSecretsFixtureServer()
        await server.useServiceFacts()
        let a = try await mac(server, passkey: nil)
        await a.graph.catchUp()
        let b = try await mac(server, passkey: nil)
        try await server.relabel(a.client.device.deviceId, label: "studio-mac-mini", appVersion: "fixture")
        try await server.relabel(b.client.device.deviceId, label: "travel-macbook-pro-21", appVersion: "fixture")
        await server.useFriendlyNames([a.client.device.deviceId: "Studio Mac mini", b.client.device.deviceId: "Travel MacBook"])
        await join(a, b)
        #expect(await b.client.local.value?.root == a.client.local.value?.root)
        let onB = await b.graph.summary()
        #expect(onB["copyFrom"].string == "Studio Mac mini")
        #expect(onB["devicesKnownHere"] == .array([.string("this Mac"), .string("Studio Mac mini")]))
        let onA = await a.graph.summary()
        #expect(onA["devicesKnownHere"] == .array([.string("this Mac"), .string("Travel MacBook")]))
        for line in a.lines.all + b.lines.all {
            #expect(!line.contains("studio-mac-mini") && !line.contains("travel-macbook"), "host name in: \(line)")
        }
    }
}

/// PASSWORDS-5 review fixes and the repair (service 7750c816e: `/secrets/spare/replace`).
@Suite("Cloud saved passwords — the spare key made again")
@MainActor
struct CloudSecretsSpareRepairTests {
    private struct Mac {
        let client: CloudSecretsFixtureClient
        let graph: BackendCloudSecretsGraph
        let trust: AutoTrustBox
        let lines: LogLines
    }
    private func mac(_ server: CloudSecretsFixtureServer, passkey: (any CloudSecretsPasskeyPort)?) async throws -> Mac {
        let client = try await CloudSecretsFixtureClient(server: server)
        let box = AutoTrustBox(on: true), lines = LogLines()
        let auto = CloudSecretsAutoTrust(on: { box.isOn() }, pinned: { box.pinned($0) })
        await client.coordinator.use(automatic: auto)
        await client.coordinator.use(log: lines.log)
        let graph = try BackendCloudSecretsGraph(recovery: client.coordinator, content: client.content, policy: client.policy,
            local: client.local, deviceId: client.device.deviceId, outbox: AutoOutbox(), stores: [AutoLogins([:])],
            retainConflict: { _ in }, known: nil, restoreLocalStores: {}, turnsOnBySelf: true, startAgainAvailable: true,
            deadAfter: 0, automatic: auto, passkey: passkey, log: lines.log,
            pause: { ms in if ms > 5_000 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } })
        await graph.guardPresses { false }
        return Mac(client: client, graph: graph, trust: box, lines: lines)
    }
    private func notice(_ type: String) -> CloudEvent {
        CloudEvent(v: 1, type: type, id: UUID().uuidString.lowercased(), payload: CloudValue(.object([])))
    }
    private func join(_ a: Mac, _ b: Mac) async {
        a.trust.trust(b.client.device, name: "MacBook Pro"); b.trust.trust(a.client.device, name: "Mac mini")
        await b.graph.catchUp()
        await a.graph.event(notice("approval"))
        await b.graph.event(notice("vault"))
    }
    /// The Mac mini's spare (its passkey `cred-a`); the MacBook answers its old sheet afterwards (`cred-b`), which
    /// replaced the spare's passkey: the MacBook shows the warning.
    private func orphaned() async throws -> (server: CloudSecretsFixtureServer, a: Mac, b: Mac, late: FixturePasskey) {
        let server = CloudSecretsFixtureServer()
        await server.useServiceFacts()
        let a = try await mac(server, passkey: nil)
        await a.graph.catchUp()
        let late = FixturePasskey(server: server, id: "cred-b")
        await late.hold()
        let b = try await mac(server, passkey: late)
        await join(a, b)
        let offer = Task { await b.client.coordinator.makeSpare(passkey: late) }
        await late.untilShown()
        #expect(await a.client.coordinator.makeSpare(passkey: FixturePasskey(server: server, id: "cred-a")) == .added)
        await late.answer()
        _ = await offer.value
        await late.hold(false)
        #expect(await b.graph.page().spareWarning == BackendCloudSecretsWords.spareOrphaned)
        return (server, a, b, late)
    }

    // Review fix 1: both sheets open; the Mac mini's spare is made "20 seconds" later, inside the MacBook's 60-s notice
    // floor (its kept status still says none): the vault notice withdraws the MacBook's sheet at once (a fresh challenge).
    @Test func aSpareMadeInsideTheNoticeFloorWithdrawsTheOtherSheetAtOnce() async throws {
        let server = CloudSecretsFixtureServer()
        await server.useServiceFacts()
        let a = try await mac(server, passkey: nil)
        await a.graph.catchUp()
        let b = try await mac(server, passkey: nil)
        await join(a, b)
        let sheetA = FixturePasskey(server: server, id: "cred-a"), sheetB = FixturePasskey(server: server, id: "cred-b")
        await sheetA.hold(); await sheetB.hold()
        let offerA = Task { await a.client.coordinator.makeSpare(passkey: sheetA) }
        let offerB = Task { await b.client.coordinator.makeSpare(passkey: sheetB) }
        await sheetA.untilShown(); await sheetB.untilShown()
        await server.freezeStatus(for: b.client.device.deviceId)     // the MacBook reads its kept "no spare" answer
        await sheetA.answer()
        #expect(await offerA.value == .added)
        await b.graph.event(notice("vault"))
        #expect(await offerB.value == .notOffered)
        #expect(await sheetB.withdrawn == 1)
        #expect(await server.spares.count == 1)
        #expect(b.lines.all.contains(CloudSecretsLog.prefix + "passkey spare key: sheet withdrawn: one was just made on another device"))
    }

    // Review fix 3: the automatic answer is named by the name THIS Mac saved, not the account's friendly name.
    @Test func theAutomaticAnswerIsNamedByTheNameThisMacSaved() async throws {
        let server = CloudSecretsFixtureServer()
        await server.useServiceFacts()
        let a = try await mac(server, passkey: nil)
        await a.graph.catchUp()
        let b = try await mac(server, passkey: nil)
        await server.useFriendlyNames([b.client.device.deviceId: "Travel MacBook"])
        await join(a, b)
        #expect(await b.client.local.value?.root == a.client.local.value?.root)
        #expect(a.lines.all.contains(CloudSecretsLog.prefix + "answered a request from MacBook Pro by itself"))
        #expect(!a.lines.all.contains { $0.contains("answered a request from Travel MacBook") })
    }

    // Repair: the spare's passkey is still on this Mac (the system refuses the excluded one): nothing is replaced.
    @Test func theSparesPasskeyStillHereClearsTheWarningAndReplacesNothing() async throws {
        let (server, _, b, late) = try await orphaned()
        await late.holding(["cred-a"])
        await b.graph.perform(.repairSpare)
        #expect(await late.excluded == [Data("cred-a".utf8)])
        let page = await b.graph.page()
        #expect(page.spareWarning == nil && !page.canRepairSpare)
        #expect(page.spareNote == "Your spare key still works.")
        #expect(await server.replaceRequests.isEmpty)
        #expect(await server.spares.first?.credentialId == CloudSecretsCrypto.encode(Data("cred-a".utf8)))
    }

    // Repair: otherwise a fresh passkey, a signed replace naming the stored spare, and the line on every Mac.
    @Test func otherwiseTheSpareIsReplacedSignedAndSaidOnEveryMac() async throws {
        let (server, a, b, late) = try await orphaned()
        let sheetsBefore = await late.sheets
        await b.graph.perform(.repairSpare)
        #expect(await late.sheets == sheetsBefore + 1)               // a fresh sheet, never the refused add's registration
        let sent = try #require(await server.replaceRequests.first)
        #expect(sent.replaces == CloudSecretsCrypto.encode(Data("cred-a".utf8)))
        #expect(sent.credentialId == CloudSecretsCrypto.encode(Data("cred-b".utf8)))
        let onB = await b.graph.page()
        #expect(onB.spareWarning == nil)
        #expect(onB.spareReplaced == BackendCloudSecretsWords.spareReplaced(nil, at: CloudSecretsFixtureServer.now))
        #expect(await a.graph.page().spareReplaced == BackendCloudSecretsWords.spareReplaced("Fixture Mac", at: CloudSecretsFixtureServer.now))
        #expect(b.lines.all.contains(CloudSecretsLog.prefix + "passkey spare key: replaced on this Mac (made again with a new passkey)"))
    }

    // The signed text, exactly as the service builds it (spareReplaceMessage, sorted keys).
    @Test func theReplaceSignatureCoversExactlyTheServicesText() throws {
        let spare = CloudSecretsSpare(v: 1, kind: "passkey", credentialId: "cred-2", epoch: 3, nonce: "bm9uY2U", ciphertext: "Y2lwaGVy",
                                      tag: "dGFn", createdAt: 7, deviceName: "Mac mini")
        let hash = CloudSecretsCrypto.hash(try CloudSecretsCanonical.encode(spare))
        let text = try CloudSecretsProof.spareReplace(sub: "sub-1", by: "device-1", epoch: 3, credentialId: "cred-2", spare: spare, replaces: "cred-1")
        #expect(String(decoding: text, as: UTF8.self)
            == #"{"by":"device-1","credentialId":"cred-2","epoch":3,"purpose":"TD-PASSWORDS-SPARE-REPLACE-1","replaces":"cred-1","spareHash":"\#(hash)","sub":"sub-1"}"#)
    }

    // Each refusal of the spare routes in its own plain words.
    @Test func eachRefusalHasItsOwnWords() {
        func words(_ code: String) -> String {
            CloudSecretsLog.spareCause(CloudFailure.remote(.init(code: code, message: "x", retryable: false, requestId: "r")))
        }
        #expect(words("spare_exists") == "a spare key is already on file for this key (spare_exists)")
        #expect(words("no_spare") == "there is no spare key on file to replace (no_spare)")
        #expect(words("spare_changed") == "the spare key was changed on another device meanwhile (spare_changed)")
        #expect(words("spare_unchanged") == "the new passkey is the one already on file (spare_unchanged)")
        #expect(words("version_changed") == "saved passwords changed meanwhile on another device (version_changed)")
        #expect(words("approval_expired") == "the request ran out before the passkey was made (approval_expired)")
        #expect(words("rate_limited") == "the spare key was replaced too often this hour; try again later (rate_limited)")
        #expect(words("not_approved") == "this Mac may not change the spare key (not_approved)")
        #expect(words("passkey_signature") == "the service did not accept the new passkey (passkey_signature)")
        #expect(words("spare_signature") == "the service did not accept this Mac's signature (spare_signature)")
        for code in ["spare_exists", "no_spare", "spare_changed", "spare_unchanged", "rate_limited", "spare_signature"] {
            #expect(CloudSecretsLog.safe(CloudSecretsLog.prefix + "passkey spare key: add refused: " + words(code)))
        }
    }

    // A replace that cannot be made is said on the page in those words (here: no spare on file any more).
    @Test func aRefusedReplaceIsSaidInItsWords() async throws {
        let (server, _, b, _) = try await orphaned()
        await server.clearSpares()
        await b.graph.perform(.repairSpare)
        #expect(await b.graph.page().spareNote == "Your spare key was not made again: there is no spare key on file to replace (no_spare).")
        #expect(await server.replaceRequests.isEmpty)
    }

    // His press only: refused right after this Mac was controlled from another device; no sheet.
    @Test func aPressRightAfterRemoteControlIsRefused() async throws {
        let (server, _, b, late) = try await orphaned()
        let sheetsBefore = await late.sheets
        await b.graph.guardPresses { true }
        await b.graph.perform(.repairSpare)
        #expect(await b.graph.page().problem == BackendCloudSecretsWords.pressRefused)
        #expect(await late.sheets == sheetsBefore)
        #expect(await server.replaceRequests.isEmpty)
        #expect(b.lines.all.contains(CloudSecretsLog.prefix + "Make my spare key again refused: this Mac was just controlled from another device"))
    }
}

/// PASSWORDS-5 point 7: at start the first status read waits for the account's connection, and the readers at that
/// moment share ONE read (each Mac sent three or four, and those that went out before the connection said "the last
/// answer did not arrive").
@Suite("Cloud saved passwords — one status read at start")
struct CloudSecretsStartReadTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var reads: Int { lock.withLock { count } }
    }
    @Test func theFirstStatusReadsWaitForTheConnectionAndGoOutOnce() async throws {
        let counter = Counter(), lines = LogLines()
        let status = CloudSecretsStatus(state: .ready, epoch: 1, version: CloudSequence(1), recoveryReady: true,
                                        approvedDeviceCount: 2, pendingApprovals: [])
        let cache = BackendCloudSecretsStatusCache(now: { 1_800_000_000_000 },
            sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) }, holdFirstReadMs: 20_000)
        cache.use(log: lines.log)
        let sink = BackendCloudSecretsEventSink(statusCache: cache)
        let control = BackendCloudSecretsLean.control(send: { method, path, _, _ in
            if method == "GET", path == "/secrets/status" { counter.add(); return try CloudSecretsCanonical.encode(status) }
            throw CloudFailure.unavailable
        }, devices: { CloudDeviceList(devices: []) }, statusCache: cache)
        let readers = (0..<4).map { _ in Task { try await control.status() } }
        while cache.heldReads < 4 { await Task.yield() }
        #expect(counter.reads == 0)
        sink.post(CloudEvent(v: 1, type: "hello", id: UUID().uuidString.lowercased(), payload: CloudValue(.object([]))))
        for reader in readers { #expect(try await reader.value == status) }
        #expect(counter.reads == 1)
        #expect(lines.all.filter { $0.contains("status read (reason: ") } == [CloudSecretsLog.prefix + "status read (reason: app start)"])
        #expect(!lines.all.contains { $0.contains("did not arrive") })
    }
}

/// Opens once; every waiter (before or after) goes on.
actor SpareGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let all = waiters; waiters = []
        for waiter in all { waiter.resume() }
    }
}
