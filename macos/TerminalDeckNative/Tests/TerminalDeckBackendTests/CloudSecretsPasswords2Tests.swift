import Foundation
import Testing
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// PASSWORDS-2 (owner, 13-14 Nov): saved passwords open by themselves on his signed-in devices, with the stricter
/// setting "Ask for my passkey on each new device" (off by default), and "Start again" when nobody can open the copy.
/// Real encryption (CryptoKit keys, sealed envelopes), the fixture service with the production service's shapes
/// (td-cloud 2fb865f1: signed requests, reset without a ticket) plus the stricter setting's relay (follow-up),
/// in-memory key stores, no Keychain, no network, no real-time waits.
@Suite("Cloud saved passwords — PASSWORDS-2")
@MainActor
struct CloudSecretsPasswords2Tests {
    struct Mac {
        let client: CloudSecretsFixtureClient
        let graph: BackendCloudSecretsGraph
        let trust: AutoTrustBox
        let logins: AutoLogins
    }
    /// `build: .older` = a Mac on an earlier build: no automatic hand-over wired (it neither signs nor answers by itself).
    enum Build { case current, older }
    private func mac(_ server: CloudSecretsFixtureServer, build: Build = .current, deadAfter: Int64 = 0,
                     logins: [String: String] = [:]) async throws -> Mac {
        let client = try await CloudSecretsFixtureClient(server: server)
        let box = AutoTrustBox(on: true)
        let auto: CloudSecretsAutoTrust? = build == .current
            ? CloudSecretsAutoTrust(on: { box.isOn() }, pinned: { box.pinned($0) },
                                    answeredBefore: { box.answeredBefore($0, $1) }, remember: { box.remember($0, $1) })
            : nil
        await client.coordinator.use(automatic: auto)
        let store = AutoLogins(logins)
        let graph = try BackendCloudSecretsGraph(recovery: client.coordinator, content: client.content, policy: client.policy,
            local: client.local, deviceId: client.device.deviceId, outbox: AutoOutbox(), stores: [store],
            retainConflict: { _ in }, known: nil, restoreLocalStores: {}, turnsOnBySelf: build == .current,
            startAgainAvailable: build == .current, deadAfter: deadAfter, automatic: auto,
            pause: { ms in if ms > 5_000 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } })
        await graph.guardPresses { false }                         // no remote input in a test, unless a test says so
        return Mac(client: client, graph: graph, trust: box, logins: store)
    }
    private func notice(_ type: String) -> CloudEvent {
        CloudEvent(v: 1, type: type, id: UUID().uuidString.lowercased(), payload: CloudValue(.object([])))
    }
    private func pair(_ a: Mac, _ b: Mac) {
        a.trust.trust(b.client.device, name: "MacBook Pro")
        b.trust.trust(a.client.device, name: "Mac mini")
    }
    private func nothingShown(_ m: Mac) async -> Bool {
        let ui = m.client.ui
        let words = await ui.confirmationCount, shown = await ui.displays, codes = await ui.transferPrompts
        return words == 0 && shown.isEmpty && codes.isEmpty
    }
    /// A on, holding the key; B asked by itself (signed). Returns B's pending approval.
    private func signedRequest(_ server: CloudSecretsFixtureServer, _ a: Mac, _ b: Mac) async throws -> CloudApproval {
        await a.graph.catchUp()
        pair(a, b)
        await b.graph.catchUp()
        let approval = try #require(await server.approvals.values.first { $0.targetDeviceId == b.client.device.deviceId })
        #expect(await server.requestSignatures[approval.approvalId] != nil)
        return approval
    }

    // 1. Automatic opening on a second Mac with a signed request: no code, no click, no sheet on either Mac.
    @Test func aSecondMacOpensByItselfFromASignedRequest() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await mac(server), b = try await mac(server)
        _ = try await signedRequest(server, a, b)
        await a.graph.event(notice("approval"))
        await b.graph.event(notice("vault"))
        #expect(await b.client.local.value?.root == a.client.local.value?.root)
        #expect(await nothingShown(a))
        #expect(await nothingShown(b))
        #expect(await a.client.local.book?.answered.count == 1)
    }

    // 2. An unsigned request, a wrongly signed one, and a signature moved from another request, generation or account
    // are never answered by themselves; a signature that does not verify is never even shown to the person.
    @Test func unsignedWronglySignedOrReplayedRequestsAreNeverAnsweredByThemselves() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await mac(server), b = try await mac(server)
        let approval = try await signedRequest(server, a, b)
        let real = try #require(await server.requestSignatures[approval.approvalId])
        let target = b.client.device
        func sign(_ bytes: Data, with keys: CloudSecretsFixtureKeys) async throws -> String {
            CloudSecretsCrypto.encode(try await keys.signDevicePayload(bytes))
        }
        let forged: [String?] = [
            nil,                                                                           // unsigned (older build)
            try await sign(CloudSecretsProof.request(sub: CloudSecretsFixtureServer.sub, approval: approval,
                wrapPublicJwk: target.wrapPublicJwk, epoch: 1), with: CloudSecretsFixtureKeys()),   // someone else's key
            try await sign(CloudSecretsProof.request(sub: CloudSecretsFixtureServer.sub, approval: approval,
                wrapPublicJwk: target.wrapPublicJwk, epoch: 2), with: b.client.keys),               // another generation
            try await sign(CloudSecretsProof.request(sub: "22222222-2222-4222-8222-222222222222", approval: approval,
                wrapPublicJwk: target.wrapPublicJwk, epoch: 1), with: b.client.keys),               // another account
        ]
        for signature in forged {
            await server.setSignature(approval.approvalId, signature)
            await a.graph.event(notice("approval"))
            #expect(await server.usedApprovals.isEmpty)
        }
        // A signature that belongs to ANOTHER request of the same device.
        let other = try await b.client.coordinator.requestApproval()
        await server.setSignature(other.approvalId, real)
        await a.graph.event(notice("approval"))
        #expect(await server.usedApprovals.isEmpty)
        // A present signature that does not verify: the person's Review refuses before any sheet.
        await #expect(throws: (any Error).self) { try await a.client.coordinator.approve(id: other.approvalId) }
        #expect(await a.client.ui.displays.isEmpty)
        #expect(await b.client.local.value == nil)
    }

    // 3. A wrapping key swapped in by the service (signing key pinned, key hash recomputed) is refused.
    @Test func aSwappedWrappingKeyIsRefused() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await mac(server), b = try await mac(server)
        let approval = try await signedRequest(server, a, b)
        let real = b.client.device
        let swapped = CloudDeviceRegistration(deviceId: real.deviceId, label: real.label, platform: real.platform, appVersion: real.appVersion,
            signPublicJwk: real.signPublicJwk, wrapPublicJwk: try CloudSecretsFixtureKeys().registration(real.deviceId).wrapPublicJwk)
        await server.substitute(swapped)
        await server.forgeApprovalHash(approval.approvalId, try CloudSecretsCrypto.keyHash(swapped))
        await a.graph.event(notice("approval"))
        #expect(await server.usedApprovals.isEmpty)
        #expect(await a.client.local.book?.answered.isEmpty ?? true)
    }

    // 4. Condition (a): "answered" sits beside the key, written before the answer: losing every file-like record does
    // not reset it, and a book that cannot be written (or read) means no automatic answer at all.
    @Test func theAnsweredRecordSurvivesADeletedFileAndIsWrittenFirst() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await mac(server), b = try await mac(server)
        _ = try await signedRequest(server, a, b)
        await a.graph.event(notice("approval"))
        await b.graph.event(notice("vault"))
        #expect(await server.usedApprovals.count == 1)
        a.trust.forgetAnswers()                                    // the "file" is gone
        await b.client.local.loseKey()
        let again = try await b.client.coordinator.requestApproval()
        await a.graph.event(notice("approval"))
        #expect(await server.usedApprovals.count == 1)             // still answered once: waits for a person
        #expect(await a.graph.page().approvals.map(\.id) == [again.approvalId])
        // A third Mac, while A's book cannot be written: nothing goes out by itself.
        let c = try await mac(server)
        a.trust.trust(c.client.device, name: "iMac"); c.trust.trust(a.client.device, name: "Mac mini")
        await c.graph.catchUp()
        await a.client.local.breakBook(true)
        await a.graph.event(notice("approval"))
        #expect(await server.usedApprovals.count == 1)
        await a.client.local.breakBook(false)
        await a.graph.event(notice("approval"))
        #expect(await server.usedApprovals.count == 2)
    }

    // 5. Condition (b): this Mac's own copy of an OLDER key generation than it has seen is never reopened.
    @Test func anOlderGenerationIsRefused() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await mac(server, deadAfter: 1_000_000)
        await a.client.local.rejectWrites()
        await a.graph.catchUp()                                    // Cloud took the set-up; the key never landed here
        #expect(await server.epoch == 1)
        #expect(await a.client.local.value == nil)
        await a.client.local.acceptWrites()
        await a.client.local.saveSeenCloudEpoch(2)                 // this Mac has already seen generation 2
        #expect(try await a.client.coordinator.reopenOwnCopy() == false)
        await a.client.local.saveSeenCloudEpoch(1)
        #expect(try await a.client.coordinator.reopenOwnCopy() == true)
    }

    // 6. Condition (d): "Turn on" after an interrupted set-up opens this Mac's own copy first (no second vault).
    @Test func turnOnAfterAnInterruptedSetUpReopensFirst() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await mac(server, deadAfter: 1_000_000)
        await a.client.local.rejectWrites()
        await a.graph.catchUp()
        await a.client.local.acceptWrites()
        await a.graph.perform(.setup)
        #expect(await server.epoch == 1)
        #expect(await server.archives == 0)
        #expect(await a.graph.page().standing == .protected)
    }

    // 7. The stricter setting on: nothing automatic; his click on another device, with the code shown on BOTH Macs
    // (review blocker 3), opens it; the setting follows him to his other Macs signed; a relayed "off" (a replay, a
    // stranger's, even his own from another device) never turns it off there (review blocker 2).
    @Test func theStricterSettingStopsEveryAutomaticAnswer() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await mac(server), b = try await mac(server)
        await a.graph.catchUp()
        await a.graph.setAskOnNewDevice(true)
        #expect(await a.graph.page().askOnNewDevice == true)
        #expect(await server.askPolicy?.askOnNewDevice == true)
        pair(a, b)
        await b.graph.catchUp()
        let pending = await b.graph.page()
        #expect(BackendCloudSecretsWords.state(pending) == BackendCloudSecretsWords.waitingForClick)
        await a.graph.event(notice("approval"))
        #expect(await server.usedApprovals.isEmpty)
        let id = try #require(await a.graph.page().approvals.first?.id)
        try await a.client.coordinator.approve(id: id)              // his click
        let shown = await a.client.ui.displays, asked = await b.client.ui.displays
        #expect(shown.count == 1 && !shown[0].matchingCode.isEmpty && shown[0].deviceName == "MacBook Pro")
        #expect(asked.count == 1 && asked[0].matchingCode == shown[0].matchingCode)
        await b.graph.event(notice("vault"))
        #expect(await b.client.local.value?.root == a.client.local.value?.root)
        #expect(await b.client.ui.transferPrompts.isEmpty)
        // B now holds the key and applies the setting it received, signed by A (pinned on B).
        #expect(await b.client.coordinator.askOnNewDevice() == true)
        // An older "off" replayed, and an "off" signed by a device B does not list: both ignored.
        let stranger = CloudSecretsFixtureKeys(), strangerId = UUID().uuidString.lowercased()
        let at = CloudSecretsFixtureServer.now + 10
        let foreign = CloudSecretsAskPolicy(askOnNewDevice: false, at: at, by: strangerId, signature: CloudSecretsCrypto.encode(
            try await stranger.signDevicePayload(CloudSecretsProof.askPolicy(sub: CloudSecretsFixtureServer.sub, askOnNewDevice: false, at: at, by: strangerId))))
        await server.replacePolicy(foreign)
        #expect(await b.client.coordinator.askOnNewDevice() == true)
        let old = CloudSecretsAskPolicy(askOnNewDevice: false, at: 5, by: a.client.device.deviceId, signature: CloudSecretsCrypto.encode(
            try await a.client.keys.signDevicePayload(CloudSecretsProof.askPolicy(sub: CloudSecretsFixtureServer.sub, askOnNewDevice: false, at: 5, by: a.client.device.deviceId))))
        await server.replacePolicy(old)
        #expect(await b.client.coordinator.askOnNewDevice() == true)
        // His own "off" on A stays on A: B keeps it on and says so beside its switch.
        await a.graph.setAskOnNewDevice(false)
        #expect(await b.client.coordinator.askOnNewDevice() == true)
        #expect(await b.graph.page().askOffElsewhere)
    }

    // 7b. A service without the relay route: the setting still holds on the Mac where he set it.
    @Test func theStricterSettingHoldsOnThisMacWithoutTheServiceRoute() async throws {
        let server = CloudSecretsFixtureServer()
        await server.setPolicyRoute(false)
        let a = try await mac(server), b = try await mac(server)
        await a.graph.catchUp()
        await a.graph.setAskOnNewDevice(true)
        #expect(await a.graph.page().askOnNewDevice == true)
        _ = try await signedRequest(server, a, b)
        await a.graph.event(notice("approval"))
        #expect(await server.usedApprovals.isEmpty)
    }

    // 8. "Start again" when truly nobody can open the copy: a fresh copy from this Mac, no ticket, his logins kept;
    // refused (and then never called dead) while another Mac still has an unfinished set-up of that generation.
    @Test func startAgainOnlyWhenNobodyCanOpen() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await mac(server, deadAfter: 1_000_000)
        await a.client.local.rejectWrites()
        // INT2 fix: "unfinished" = A holds its envelope but never confirmed it (its possession did not reach the
        // service). A failed local save alone comes AFTER possession, so A would already count as approved.
        await server.fault("possession")
        await a.graph.catchUp()                                    // A's set-up is unfinished: it holds an envelope
        await server.fault(nil)
        let b = try await mac(server, logins: ["kept": "fixture-login-4"])
        await b.graph.catchUp()
        #expect(await b.graph.page().cannotOpen)                    // B cannot tell an unfinished set-up apart ...
        await b.graph.perform(.startAgain)
        #expect(await server.epoch == 1)
        #expect(await server.resetsWithoutTicket == 0)   // ... the service refuses
        #expect(await !b.graph.page().cannotOpen)                   // and B no longer says "can't be opened"
        await b.graph.catchUp()
        #expect(await !b.graph.page().cannotOpen)
        // Now truly nobody: A's unfinished copy is gone too.
        await server.forget(a.client.device.deviceId); await server.dropApproved(a.client.device.deviceId)
        let c = try await mac(server, logins: ["mine": "fixture-login-5"])
        await c.graph.catchUp()
        #expect(await c.graph.page().cannotOpen)
        await c.graph.perform(.startAgain)
        #expect(await server.epoch == 2)
        #expect(await server.resetsWithoutTicket == 1)
        #expect(await server.archives == 1)
        #expect(await c.graph.page().standing == .protected)
        #expect(c.logins.values() == ["mine": "fixture-login-5"])
        #expect(await nothingShown(c))
    }

    // 9. First run on two Macs, in both orders: one sets the copy up silently, the other opens by itself.
    @Test func firstRunOnTwoMacsInBothOrders() async throws {
        for order in 0..<2 {
            let server = CloudSecretsFixtureServer()
            let mini = try await mac(server), book = try await mac(server)
            pair(mini, book)
            let (first, second) = order == 0 ? (mini, book) : (book, mini)
            await first.graph.catchUp()
            await second.graph.catchUp()
            await first.graph.event(notice("approval"))
            await second.graph.event(notice("vault"))
            #expect(await server.epoch == 1)
            #expect(await first.client.local.value?.root == second.client.local.value?.root)
            #expect(await nothingShown(first))
            #expect(await nothingShown(second))
        }
    }

    // 10. An older build on the other Mac: it neither signs nor answers by itself; nothing is lost and nothing is
    // answered without a person. An older Mac asking: the current Mac leaves it for his click with the codes.
    @Test func anOlderBuildOnTheOtherMac() async throws {
        let server = CloudSecretsFixtureServer()
        let current = try await mac(server), older = try await mac(server, build: .older)
        await current.graph.catchUp()
        pair(current, older)
        await older.graph.catchUp()                                 // the older build asks nothing by itself
        #expect(await server.approvals.isEmpty)
        let asked = try await older.client.coordinator.requestApproval()   // its own "Ask another device"
        #expect(await server.requestSignatures.isEmpty)
        #expect(await older.client.ui.displays.count == 1)
        await current.graph.event(notice("approval"))
        #expect(await server.usedApprovals.isEmpty)                 // unsigned: never by itself
        try await current.client.coordinator.approve(id: asked.approvalId)
        #expect(await current.client.ui.displays.count == 2)        // the code sheet and the second code, as before
        // The other way round: the older Mac holds the key, the current one signs and waits; never answered by itself.
        let server2 = CloudSecretsFixtureServer()
        let olderFirst = try await mac(server2, build: .older), newer = try await mac(server2)
        try await olderFirst.graph.service.setupSilently()
        pair(olderFirst, newer)
        await newer.graph.catchUp()
        await olderFirst.graph.event(notice("approval"))
        #expect(await server2.usedApprovals.isEmpty)
        #expect(await olderFirst.graph.page().approvals.count == 1)
        #expect(BackendCloudSecretsWords.state(await newer.graph.page()) == "Opening…")
    }

    // 11. Tools: an AI reads the state; no action receives the key, changes the stricter setting or starts again.
    @Test func toolsReadButNeverDecide() async throws {
        let actions = BackendCloudSecretsTools.contribution.tools.first { $0.id == "cloud.secrets" }
        let schema = try #require(actions?.inputSchema.raw)
        let allowed = Set((schema["properties"]["action"]["enum"].elements ?? []).compactMap(\.string))
        #expect(allowed == ["status", "setup", "request_device", "open_approval", "recover", "reset"])
        let server = CloudSecretsFixtureServer()
        let a = try await mac(server)
        await a.graph.catchUp()
        let status = try await a.graph.tools.invoke("cloud.secrets", arguments: .init(.object([.init("action", .string("status"))]))).raw
        #expect(status["askOnNewDevice"].bool == false)
        for bad in ["start_again", "ask_on_new_device", "policy", "answer"] {
            await #expect(throws: (any Error).self) {
                _ = try await a.graph.tools.invoke("cloud.secrets", arguments: .init(.object([.init("action", .string(bad))])))
            }
        }
    }

    // 12. The last-device warning tells the truth for an older account with recovery words.
    @Test func theLastDeviceWarningSaysWhatIsTrue() async throws {
        let server = CloudSecretsFixtureServer()
        let client = try await CloudSecretsFixtureClient(server: server)
        try await client.coordinator.setup()                        // an older account: words confirmed
        #expect(await client.coordinator.signOutState().recoveryWordsOnFile == true)
        let silent = try await mac(CloudSecretsFixtureServer())
        await silent.graph.catchUp()
        #expect(await silent.graph.recoveryWordsOnFile() == false)
    }

    // MARK: the review of 4da59b183 (14 Nov 14:47): one test per blocker, and points 5 and 6

    // Blocker 1, changed by the owner on 15 Nov ("every single thing in cloud ... and in everywhere"): a BROWSER's request
    // is never answered by itself, never listed and never gets the click without a code, and neither is a device whose
    // recorded kind and reported kind disagree. One of his own phones, recorded here as a phone, is answered by itself
    // (CloudSecretsEverywhereTests holds the phone's own cases). The kind THIS Mac recorded with the key decides.
    // 15 Nov (later): a browser recorded and listed as a browser IS answered now (CloudSecretsBrowserAnswerTests); what
    // stays refused here is every disagreement between the kind recorded on A and the kind the service reports.
    @Test func aKindMismatchNeverGetsTheKeyByItselfButHisPhoneDoes() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await mac(server), b = try await mac(server)
        let approval = try await signedRequest(server, a, b)
        let real = b.client.device
        // (recorded kind on A, kind the service reports): a browser as it is, a browser the service calls a Mac, a phone
        // the service calls a Mac.
        for (recorded, reported) in [(CloudPlatform.web, CloudPlatform.macos), (.ios, .macos), (.web, .ios), (.ios, .web)] {
            a.trust.trust(real, name: "Browser", platform: recorded)
            await server.substitute(CloudDeviceRegistration(deviceId: real.deviceId, label: real.label, platform: reported,
                appVersion: real.appVersion, signPublicJwk: real.signPublicJwk, wrapPublicJwk: real.wrapPublicJwk))
            await a.graph.event(notice("approval"))
            #expect(await server.usedApprovals.isEmpty)
            #expect(await a.graph.page().approvals.isEmpty)
            await #expect(throws: (any Error).self) { try await a.client.coordinator.approve(id: approval.approvalId) }
            #expect(await a.client.ui.displays.isEmpty)
        }
        #expect(await b.client.local.value == nil)
        #expect(await a.client.local.book?.answered.isEmpty ?? true)
        // The same device recorded here as a phone, and the account lists it as a phone: answered by itself.
        a.trust.trust(real, name: "iPhone", platform: .ios)
        await server.substitute(CloudDeviceRegistration(deviceId: real.deviceId, label: real.label, platform: .ios,
            appVersion: real.appVersion, signPublicJwk: real.signPublicJwk, wrapPublicJwk: real.wrapPublicJwk))
        await a.graph.event(notice("approval"))
        #expect(await server.usedApprovals.count == 1)
    }

    // Blocker 2: a relayed "on" is taken; a relayed "off", even properly signed by a device this Mac lists, is not.
    // Only his own press on this Mac switches it off here; until then the page says it is still on here.
    @Test func aRelayedOffIsIgnoredAndARelayedOnIsTaken() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await mac(server), b = try await mac(server)
        _ = try await signedRequest(server, a, b)
        await a.graph.event(notice("approval"))
        await b.graph.event(notice("vault"))
        #expect(await b.client.local.value != nil)
        await a.graph.setAskOnNewDevice(true)
        #expect(await b.client.coordinator.askOnNewDevice() == true)      // relayed "on": taken
        await a.graph.setAskOnNewDevice(false)                             // signed by A, newer, "off"
        #expect(await a.client.coordinator.askOnNewDevice() == false)
        #expect(await b.client.coordinator.askOnNewDevice() == true)      // relayed "off": ignored
        let page = await b.graph.page()
        #expect(page.askOnNewDevice == true && page.askOffElsewhere)
        await b.graph.setAskOnNewDevice(false)                             // his own press on B
        #expect(await b.client.coordinator.askOnNewDevice() == false)
        #expect(await !b.graph.page().askOffElsewhere)
    }

    // Blocker 3: with the stricter setting the code shows on BOTH devices (the answering Mac always); if the service
    // hides the setting, the new device shows none and the answering Mac still shows its code (he refuses there).
    // While the service cannot carry the setting the page says "On this Mac only".
    @Test func theStricterModeShowsTheCodeOnBothSides() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await mac(server), b = try await mac(server)
        await a.graph.catchUp()
        await a.graph.setAskOnNewDevice(true)
        #expect(await !a.graph.page().askThisMacOnly)
        pair(a, b)
        await b.graph.catchUp()
        let asked = await b.client.ui.displays
        #expect(asked.count == 1 && !asked[0].matchingCode.isEmpty)
        await a.graph.event(notice("approval"))
        #expect(await server.usedApprovals.isEmpty)
        let id = try #require(await a.graph.page().approvals.first?.id)
        try await a.client.coordinator.approve(id: id)
        let shown = await a.client.ui.displays
        #expect(shown.count == 1 && shown[0].matchingCode == asked[0].matchingCode)
        await b.graph.event(notice("vault"))
        #expect(await b.client.local.value?.root == a.client.local.value?.root)
        // A service that does not carry (or hides) the setting.
        let hidden = CloudSecretsFixtureServer()
        await hidden.setPolicyRoute(false)
        let c = try await mac(hidden), d = try await mac(hidden)
        await c.graph.catchUp()
        await c.graph.setAskOnNewDevice(true)
        #expect(await c.graph.page().askThisMacOnly)
        pair(c, d)
        await d.graph.catchUp()
        #expect(await d.client.ui.displays.isEmpty)
        let other = try #require(await c.graph.page().approvals.first?.id)
        await c.client.ui.setAllow(false)                                  // he sees no code there: he refuses
        try? await c.client.coordinator.approve(id: other)
        let refused = await c.client.ui.displays
        #expect(refused.count == 1 && !refused[0].matchingCode.isEmpty)
        #expect(await d.client.local.value == nil)
    }

    // Blocker 4: a press on the stricter switch or on "Start again" right after the app's own remote input is refused,
    // with one plain line, and changes nothing.
    @Test func aRemoteInputPressOnTheSwitchOrStartAgainIsRefused() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await mac(server)
        await a.graph.catchUp()
        await a.graph.guardPresses { true }
        await a.graph.setAskOnNewDevice(true)
        #expect(await a.client.coordinator.askOnNewDevice() == false)
        #expect(await server.askPolicy == nil)
        #expect(await a.graph.page().problem == BackendCloudSecretsWords.pressRefused)
        // "Start again" where truly nobody can open the copy.
        let dead = CloudSecretsFixtureServer()
        let gone = try await mac(dead, deadAfter: 1_000_000)
        await gone.client.local.rejectWrites()
        await gone.graph.catchUp()
        await dead.forget(gone.client.device.deviceId); await dead.dropApproved(gone.client.device.deviceId)
        let c = try await mac(dead)
        await c.graph.catchUp()
        #expect(await c.graph.page().cannotOpen)
        await c.graph.guardPresses { true }
        await c.graph.perform(.startAgain)
        #expect(await dead.epoch == 1)
        #expect(await dead.resetsWithoutTicket == 0)
        #expect(await dead.archives == 0)
        #expect(await c.graph.page().problem == BackendCloudSecretsWords.pressRefused)
    }

    // Point 5: "held elsewhere" is cleared on a devices notice, so a device that held an unfinished set-up and is
    // then removed for good does not leave "Opening…" up until a restart.
    @Test func heldElsewhereClearsOnADevicesNotice() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await mac(server, deadAfter: 1_000_000)
        await a.client.local.rejectWrites()
        // INT2 fix: "unfinished" = A holds its envelope but never confirmed it (its possession did not reach the
        // service). A failed local save alone comes AFTER possession, so A would already count as approved.
        await server.fault("possession")
        await a.graph.catchUp()                                    // A's set-up is unfinished
        await server.fault(nil)
        let b = try await mac(server)
        await b.graph.catchUp()
        await b.graph.perform(.startAgain)                         // refused: A still holds it ("held elsewhere")
        #expect(await !b.graph.page().cannotOpen)
        await server.forget(a.client.device.deviceId); await server.dropApproved(a.client.device.deviceId)
        await b.graph.catchUp()
        #expect(await !b.graph.page().cannotOpen)                  // still waiting on A for this generation
        await b.graph.event(notice("devices"))                     // A removed: looked at again
        #expect(await b.graph.page().cannotOpen)
    }

    // Point 6: a request whose signature is present and does not verify is not listed (its button could only fail);
    // an unsigned one (an older build) is listed for his click with the codes.
    @Test func aWronglySignedRequestIsNotListed() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await mac(server), b = try await mac(server)
        let approval = try await signedRequest(server, a, b)
        let forged = CloudSecretsCrypto.encode(try await CloudSecretsFixtureKeys().signDevicePayload(CloudSecretsProof.request(
            sub: CloudSecretsFixtureServer.sub, approval: approval, wrapPublicJwk: b.client.device.wrapPublicJwk, epoch: 1)))
        await server.setSignature(approval.approvalId, forged)
        #expect(await a.graph.page().approvals.isEmpty)
        await server.setSignature(approval.approvalId, nil)
        #expect(await a.graph.page().approvals.map(\.id) == [approval.approvalId])
    }

    // Service fit (72959fbbd), B1 + B2: the new service never signs an OFF; it says who switched it off and when
    // (`askPolicyTurnedOff`). Shown beside the switch, never taken; a Mac with no key reads it as "off" for its hint.
    @Test func theServicesPlainOffIsShownButNeverTaken() async throws {
        let server = CloudSecretsFixtureServer()
        await server.useServiceFacts()
        let a = try await mac(server), b = try await mac(server)
        _ = try await signedRequest(server, a, b)
        await a.graph.event(notice("approval"))
        await b.graph.event(notice("vault"))
        #expect(await b.client.local.value != nil)
        let c = try await mac(server)                                      // no key: only its hint reads the setting
        #expect(await !c.client.coordinator.askHint())                      // nothing set: no field = off
        await a.graph.setAskOnNewDevice(true)
        #expect(await b.client.coordinator.askOnNewDevice() == true)      // the signed ON is taken
        #expect(await c.client.coordinator.askHint())
        await a.graph.setAskOnNewDevice(false)                             // the service now says only "turned off by A"
        let raw = try await server.handle(caller: b.client.device.deviceId, method: "GET", path: "/secrets/status", body: Data(),
                                          requestId: UUID().uuidString.lowercased())
        let status = String(decoding: raw, as: UTF8.self)
        #expect(status.contains("\"askPolicyTurnedOff\"") && !status.contains("\"askPolicy\""))
        #expect(await b.client.coordinator.askOnNewDevice() == true)      // never taken
        #expect(await b.client.local.book?.askOnNewDevice == true)
        let page = await b.graph.page()
        #expect(page.askOnNewDevice == true && page.askOffElsewhere && !page.askThisMacOnly)
        #expect(await !c.client.coordinator.askHint())                      // turned off = off for the hint
        await b.graph.setAskOnNewDevice(false)                             // his own press on B
        #expect(await b.client.coordinator.askOnNewDevice() == false)
        #expect(await !b.graph.page().askOffElsewhere)
        // Today's service (no new facts): the hint reads exactly as before.
        await server.useServiceFacts(false)
        await a.graph.setAskOnNewDevice(true)
        #expect(await c.client.coordinator.askHint())
    }

    // Service fit, B3: a device that holds this generation's key but has not confirmed yet is not "nobody" when the
    // service says so (`nobodyCanOpen`); today's service keeps the earlier test (no approved device).
    @Test func theServiceSaysWhetherAnyDeviceHoldsTheKey() async throws {
        let server = CloudSecretsFixtureServer()
        await server.useServiceFacts()
        let a = try await mac(server, deadAfter: 1_000_000)
        await a.client.local.rejectWrites()
        // INT2 fix: "unfinished" = A holds its envelope but never confirmed it (its possession did not reach the
        // service). A failed local save alone comes AFTER possession, so A would already count as approved.
        await server.fault("possession")
        await a.graph.catchUp()                                    // A holds an envelope but never confirmed
        await server.fault(nil)
        let b = try await mac(server)
        #expect(await !b.client.coordinator.nobodyCanOpen())
        await b.graph.catchUp()
        #expect(await !b.graph.page().cannotOpen)
        await server.useServiceFacts(false)                        // today's service: the earlier test, as before
        #expect(await b.client.coordinator.nobodyCanOpen())
        await server.useServiceFacts()
        await server.forget(a.client.device.deviceId); await server.dropApproved(a.client.device.deviceId)
        #expect(await b.client.coordinator.nobodyCanOpen())        // now truly nobody (and no recovery words)
        await b.graph.catchUp()
        #expect(await b.graph.page().cannotOpen)
    }
}

extension CloudSecretsFixtureServer {
    func setSignature(_ approvalId: String, _ signature: String?) { requestSignatures[approvalId] = signature }
    func replacePolicy(_ value: CloudSecretsAskPolicy?) { askPolicy = value }
    func setPolicyRoute(_ on: Bool) { policyRoute = on }
}
extension AutoTrustBox {
    /// What used to be the "answered" file is gone.
    func forgetAnswers() { resetAnswered() }
}
