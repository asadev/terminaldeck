import Foundation
import Testing
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Security, 14 Nov (gaps 1 and 2): saved passwords say every state change in the app's log, in names and plain words
/// only; the read-only `cloud.secrets.status` answers the same facts; the passkey offer is used up only after the
/// service answered the add, offers itself once per start and not for a day after a cancel, and "Make a passkey spare
/// key" is his own press. Fixture service, fixture passkey, no Keychain, no network.
@Suite("Cloud saved passwords — log lines, read tool, passkey offer")
@MainActor
struct CloudSecretsLogTests {
    private func mac(_ server: CloudSecretsFixtureServer, passkey: (any CloudSecretsPasskeyPort)?, lines: LogLines) async throws
        -> (client: CloudSecretsFixtureClient, graph: BackendCloudSecretsGraph, trust: AutoTrustBox) {
        let client = try await CloudSecretsFixtureClient(server: server)
        let box = AutoTrustBox(on: true)
        let auto = CloudSecretsAutoTrust(on: { box.isOn() }, pinned: { box.pinned($0) })
        await client.coordinator.use(automatic: auto)
        await client.coordinator.use(log: lines.log)
        let graph = try BackendCloudSecretsGraph(recovery: client.coordinator, content: client.content, policy: client.policy,
            local: client.local, deviceId: client.device.deviceId, outbox: AutoOutbox(), stores: [AutoLogins([:])],
            retainConflict: { _ in }, known: nil, restoreLocalStores: {}, turnsOnBySelf: true, startAgainAvailable: true,
            deadAfter: 0, automatic: auto, passkey: passkey, log: lines.log,
            pause: { ms in if ms > 5_000 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } })
        return (client, graph, box)
    }
    /// Every line written: prefixed, passes the scan, and carries none of the ids, the account or a code.
    private func scan(_ lines: [String], forbidden: [String]) {
        for line in lines {
            #expect(line.hasPrefix(CloudSecretsLog.prefix))
            #expect(CloudSecretsLog.safe(line), "unsafe line: \(line)")
            #expect(!line.contains(CloudSecretsLog.withheld), "a flow wrote a line the scan had to withhold: \(line)")
            for secret in forbidden where !secret.isEmpty { #expect(!line.contains(secret), "line carries a secret or an id: \(line)") }
        }
    }

    @Test func theScanRefusesAnythingThatCouldBeASecret() {
        #expect(CloudSecretsLog.safe("cloud passwords: answered a request from Mac mini by itself"))
        #expect(CloudSecretsLog.safe("cloud passwords: passkey spare key: made on Mac mini, 14 Nov 2026 15:02"))
        #expect(!CloudSecretsLog.safe("cloud passwords: signed in as asad@example.com"))
        #expect(!CloudSecretsLog.safe("cloud passwords: device " + UUID().uuidString.lowercased()))
        #expect(!CloudSecretsLog.safe("cloud passwords: key " + CloudSecretsCrypto.encode(Data(repeating: 7, count: 32))))
        #expect(!CloudSecretsLog.safe("cloud passwords: code AB12 CD34 EF56 7890"))
        #expect(!CloudSecretsLog.safe("cloud passwords: at 1800000000000"))
        #expect(CloudSecretsLog.line("token eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiIxMjMifQ") == CloudSecretsLog.prefix + CloudSecretsLog.withheld)
        #expect(CloudSecretsLog.name("Asads-MacBook-Pro.local") == "Asads-MacBook-Pro")
        #expect(CloudSecretsLog.name("someone@example.com's Mac").contains("@") == false)
        #expect(CloudSecretsLog.name(String(repeating: "x", count: 60)).count <= 20)
        #expect(CloudSecretsLog.cause(CloudFailure.remote(.init(code: "spare_exists", message: "x", retryable: false, requestId: UUID().uuidString)))
                == "the service refused (spare_exists)")
    }

    // Each state change of a first Mac and a second Mac, the start line, and the scan over every line.
    @Test func eachStepSaysOneLineAndNoLineCarriesASecret() async throws {
        let server = CloudSecretsFixtureServer()
        await server.useServiceFacts()
        let linesA = LogLines(), linesB = LogLines()
        let a = try await mac(server, passkey: ScriptedPasskey(server: server, script: []), lines: linesA)
        await a.graph.catchUp()
        let first = linesA.all
        #expect(first.contains(CloudSecretsLog.prefix + "turning on: nothing in Cloud yet, this Mac sets the Cloud copy up"))
        #expect(first.contains(CloudSecretsLog.prefix + "set the Cloud copy up on this Mac (the first device of the account)"))
        #expect(first.contains(CloudSecretsLog.prefix + "passkey spare key: offered by itself"))
        #expect(first.contains(CloudSecretsLog.prefix + "passkey spare key: challenge asked: ok"))
        #expect(first.contains(CloudSecretsLog.prefix + "passkey spare key: system passkey sheet shown"))
        #expect(first.contains(CloudSecretsLog.prefix + "passkey spare key: add accepted by the service"))
        #expect(first.contains(CloudSecretsLog.prefix + "passkey spare key: made and confirmed"))
        let start = try #require(first.first { $0.hasPrefix(CloudSecretsLog.prefix + "at start: ") })
        #expect(start.contains("state " + BackendCloudSecretsWords.on))
        // 14 Nov: the start line is written BEFORE the passkey sheet (which waits for him), never after it.
        let startAt = try #require(first.firstIndex(of: start))
        let sheetAt = try #require(first.firstIndex(of: CloudSecretsLog.prefix + "passkey spare key: system passkey sheet shown"))
        #expect(startAt < sheetAt)
        #expect(start.contains("devices that can open it 1"))
        #expect(!start.contains("not read yet"))
        // Exactly one start line per run.
        await a.graph.catchUp()
        #expect(linesA.all.filter { $0.contains("at start: ") }.count == 1)

        let b = try await mac(server, passkey: ScriptedPasskey(server: server, script: []), lines: linesB)
        a.trust.trust(b.client.device, name: "MacBook Pro"); b.trust.trust(a.client.device, name: "Mac mini")
        await b.graph.catchUp()
        #expect(linesB.all.contains { $0.hasPrefix(CloudSecretsLog.prefix + "asked your other devices; waiting (Opening…) for ") })
        await a.graph.event(CloudEvent(v: 1, type: "approval", id: UUID().uuidString.lowercased(), payload: CloudValue(.object([]))))
        #expect(linesA.all.contains(CloudSecretsLog.prefix + "answered a request from MacBook Pro by itself"))
        await b.graph.event(CloudEvent(v: 1, type: "vault", id: UUID().uuidString.lowercased(), payload: CloudValue(.object([]))))
        #expect(linesB.all.contains(CloudSecretsLog.prefix + "opened by itself: answered by Mac mini"))
        // The stricter setting switched here, said with whether it was carried.
        await a.graph.setAskOnNewDevice(true)
        #expect(linesA.all.contains { $0.hasPrefix(CloudSecretsLog.prefix + "stricter setting (ask on each new device) switched on here; ") })

        let forbidden = [a.client.device.deviceId, b.client.device.deviceId, CloudSecretsFixtureServer.sub,
                         a.client.device.signPublicJwk.x, b.client.device.signPublicJwk.x]
        scan(linesA.all + linesB.all, forbidden: forbidden)
    }

    // A refused automatic answer says why, once.
    @Test func aRefusalSaysWhyOnce() async throws {
        let server = CloudSecretsFixtureServer()
        let linesA = LogLines()
        let a = try await mac(server, passkey: nil, lines: linesA)
        await a.graph.catchUp()
        let b = try await mac(server, passkey: nil, lines: LogLines())
        b.trust.trust(a.client.device, name: "Mac mini")      // A does not list B
        await b.graph.catchUp()
        await a.graph.event(CloudEvent(v: 1, type: "approval", id: UUID().uuidString.lowercased(), payload: CloudValue(.object([]))))
        await a.graph.event(CloudEvent(v: 1, type: "devices", id: UUID().uuidString.lowercased(), payload: CloudValue(.object([]))))
        let refusals = linesA.all.filter { $0.contains("did not answer a request from ") && $0.hasSuffix(": not listed on this Mac") }
        #expect(refusals.count == 1)
        scan(linesA.all, forbidden: [a.client.device.deviceId, b.client.device.deviceId, CloudSecretsFixtureServer.sub])
    }

    // Gap 1b: the read-only tool at the read level, answering names, counts and dates.
    @Test func theReadToolIsAtTheReadLevelAndAnswersNamesOnly() async throws {
        let server = CloudSecretsFixtureServer()
        await server.useServiceFacts()
        let a = try await mac(server, passkey: ScriptedPasskey(server: server, script: []), lines: LogLines())
        await a.graph.catchUp()
        let spec = try BackendCloudSecretsLeanTool.statusDefinition()
        #expect(spec.id == "cloud.secrets.status" && spec.tier == .read)
        let entries = try await BackendCloudSecretsLeanTool.registrations(tools: a.graph.tools, visible: { true }, summary: { await a.graph.summary() })
        #expect(entries.map { $0.0.id } == ["cloud.secrets", "cloud.secrets.status"])
        let answer = await a.graph.summary()
        #expect(answer["state"].string == BackendCloudSecretsWords.on)
        #expect(answer["since"].string != nil)
        #expect(answer["copyFrom"].string == "this Mac")
        #expect(answer["devicesThatCanOpen"].number == 1)
        #expect(answer["devicesKnownHere"] == .array([.string("this Mac")]))
        #expect(answer["stricterSettingHere"].bool == false)
        #expect(answer["passkeySpareMadeOn"].string == "this Mac")
        let text = answer.compact
        for secret in [a.client.device.deviceId, CloudSecretsFixtureServer.sub] { #expect(!text.contains(secret)) }
        #expect(!text.contains("@"))
    }

    // Gap 2: a cancelled sheet leaves the offer open and the button there; once per start; not again for a day.
    @Test func aCancelledSheetLeavesTheOfferOpen() async throws {
        let server = CloudSecretsFixtureServer()
        await server.useServiceFacts()
        let lines = LogLines(), passkey = ScriptedPasskey(server: server, script: ["cancel"])
        let a = try await mac(server, passkey: passkey, lines: lines)
        await a.graph.catchUp()
        #expect(await passkey.sheets == 1)
        #expect(await server.spares.isEmpty)
        var book = try #require(try await a.client.local.handOverBook())
        #expect(book.spareAdded == nil)
        #expect(book.spareCancelledAt == CloudSecretsFixtureServer.now)
        #expect(await a.graph.page().canMakeSpare)
        #expect(lines.all.contains(CloudSecretsLog.prefix + "passkey spare key: sheet cancelled; it offers itself again tomorrow at the earliest"))
        // Once per start.
        await a.graph.catchUp()
        #expect(await passkey.sheets == 1)
        // A new start the same day: not offered by itself.
        await a.client.coordinator.forgetThisRun()
        #expect(await a.client.coordinator.offerSpareOnce(passkey: passkey) == false)
        #expect(await passkey.sheets == 1)
        #expect(lines.all.contains { $0.hasPrefix(CloudSecretsLog.prefix + "passkey spare key: not offered by itself today: you cancelled it ") })
        // A day later: offered again, and now made; the button goes.
        book.spareCancelledAt = CloudSecretsFixtureServer.now - 25 * 3_600_000
        try await a.client.local.saveHandOverBook(book)
        await a.client.coordinator.forgetThisRun()
        #expect(await a.client.coordinator.offerSpareOnce(passkey: passkey))
        #expect(await passkey.sheets == 2)
        #expect(await server.spares.count == 1)
        let after = try #require(try await a.client.local.handOverBook())
        #expect(after.spareAdded?.contains(1) == true)
        let page = await a.graph.page()
        #expect(!page.canMakeSpare)
        #expect(page.spareMade == BackendCloudSecretsWords.spareMade(nil, at: CloudSecretsFixtureServer.now))
        // Used up only now: no further offer.
        await a.client.coordinator.forgetThisRun()
        #expect(await a.client.coordinator.offerSpareOnce(passkey: passkey) == false)
        #expect(await passkey.sheets == 2)
    }

    // Gap 2: a failed sheet leaves it open too (no one-day wait), and his press makes it.
    @Test func aFailedSheetLeavesItOpenAndHisPressMakesIt() async throws {
        let server = CloudSecretsFixtureServer()
        await server.useServiceFacts()
        let lines = LogLines(), passkey = ScriptedPasskey(server: server, script: ["fail"])
        let a = try await mac(server, passkey: passkey, lines: lines)
        await a.graph.catchUp()
        #expect(await server.spares.isEmpty)
        #expect(try await a.client.local.handOverBook()?.spareCancelledAt == nil)
        #expect(await a.graph.page().canMakeSpare)
        #expect(lines.all.contains(CloudSecretsLog.prefix + "passkey spare key: not made: " + ScriptedPasskey.failure))
        await a.graph.perform(.makeSpare)
        #expect(await server.spares.count == 1)
        #expect(lines.all.contains(CloudSecretsLog.prefix + "passkey spare key: asked for by your press"))
        let page = await a.graph.page()
        #expect(page.problem == nil && !page.canMakeSpare && page.spareMade != nil)
    }

    // Gap 2: the button refuses a press right after remote control, and shows no sheet.
    @Test func aPressFromRemoteControlIsRefused() async throws {
        let server = CloudSecretsFixtureServer()
        await server.useServiceFacts()
        let lines = LogLines(), passkey = ScriptedPasskey(server: server, script: ["fail"])
        let a = try await mac(server, passkey: passkey, lines: lines)
        await a.graph.catchUp()
        #expect(await passkey.sheets == 1)
        await a.graph.guardPresses { true }
        await a.graph.perform(.makeSpare)
        #expect(await passkey.sheets == 1)
        #expect(await server.spares.isEmpty)
        let page = await a.graph.page()
        #expect(page.problem == BackendCloudSecretsWords.pressRefused)
        #expect(page.canMakeSpare)
        #expect(lines.all.contains(CloudSecretsLog.prefix + "Make a passkey spare key refused: this Mac was just controlled from another device"))
    }
}

/// Review fixes of 2239cccdb: the read tool's kept answer, a name with a line break, the two signature wordings.
@Suite("Cloud saved passwords — review fixes of the log and the read tool")
@MainActor
struct CloudSecretsLogReviewTests {
    private func mac(_ server: CloudSecretsFixtureServer, lines: LogLines) async throws
        -> (client: CloudSecretsFixtureClient, graph: BackendCloudSecretsGraph, trust: AutoTrustBox, auto: CloudSecretsAutoTrust) {
        let client = try await CloudSecretsFixtureClient(server: server)
        let box = AutoTrustBox(on: true)
        let auto = CloudSecretsAutoTrust(on: { box.isOn() }, pinned: { box.pinned($0) })
        await client.coordinator.use(automatic: auto)
        await client.coordinator.use(log: lines.log)
        let graph = try BackendCloudSecretsGraph(recovery: client.coordinator, content: client.content, policy: client.policy,
            local: client.local, deviceId: client.device.deviceId, outbox: AutoOutbox(), stores: [AutoLogins([:])],
            retainConflict: { _ in }, known: nil, restoreLocalStores: {}, turnsOnBySelf: true, startAgainAvailable: true,
            deadAfter: 0, automatic: auto, passkey: nil, log: lines.log,
            pause: { ms in if ms > 5_000 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } })
        return (client, graph, box, auto)
    }

    // Fix 1: two calls within 30 seconds make ONE round of service requests (the start line's round included); a
    // change of state on this Mac drops the kept answer.
    @Test func theReadToolKeepsItsAnswerForThirtySeconds() async throws {
        let server = CloudSecretsFixtureServer()
        await server.useServiceFacts()
        let a = try await mac(server, lines: LogLines())
        await a.graph.catchUp()                         // writes the start line from a fresh round, and keeps it
        let before = await server.requestCount
        let first = await a.graph.summary()
        let second = await a.graph.summary()
        #expect(await server.requestCount == before)    // both from the start line's kept answer
        #expect(first == second)
        await a.graph.setAskOnNewDevice(true)           // a change of state here
        let afterChange = await server.requestCount
        let third = await a.graph.summary()
        #expect(await server.requestCount > afterChange)
        #expect(third["stricterSettingHere"].bool == true)
        let settled = await server.requestCount
        _ = await a.graph.summary()
        #expect(await server.requestCount == settled)
    }

    // Fix 2: a line break or a control character inside a name never starts a line of its own.
    @Test func aNameWithALineBreakStaysOnOneLine() {
        let name = CloudSecretsLog.name("Mac\ncloud passwords: opened\r\u{0007}x")
        #expect(!name.contains("\n") && !name.contains("\r") && !name.contains("\u{0007}"))
        let line = CloudSecretsLog.line("answered a request from " + name + " by itself")
        #expect(line.split(whereSeparator: \.isNewline).count == 1)
    }

    // Fix 3: a real mismatch is "wrong signature"; signatures that could not be read are said as such.
    @Test func aSignatureThatCannotBeReadIsNotCalledWrong() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await mac(server, lines: LogLines())
        await a.graph.catchUp()
        let b = try await mac(server, lines: LogLines())
        a.trust.trust(b.client.device, name: "MacBook Pro"); b.trust.trust(a.client.device, name: "Mac mini")
        a.trust.stop(b.client.device.deviceId)          // A does not answer by itself while the request is set up
        await b.graph.catchUp()
        a.trust.trust(b.client.device, name: "MacBook Pro")
        let approval = try #require(await server.approvals.values.first { $0.targetDeviceId == b.client.device.deviceId })
        let subject = CloudSubject(issuer: CloudWire.issuer, sub: CloudSecretsFixtureServer.sub)
        for (mode, wording) in [(SignatureReads.Mode.fail, ": could not check the request: no answer from the service"),
                                (SignatureReads.Mode.forge, ": wrong signature")] {
            let lines = LogLines()
            let control = SignatureReads(inner: a.client.control, mode: mode)
            let coordinator = CloudRecoveryCoordinator(subject: subject, device: a.client.device, keys: a.client.keys, local: a.client.local,
                control: control, words: BackendCloudRecoveryMnemonic(), interaction: a.client.ui, policy: a.client.policy,
                resetTicket: { CloudSecretsFixtureServer.resetTicket })
            await coordinator.use(automatic: a.auto)
            await coordinator.use(log: lines.log)
            #expect(try await coordinator.answerAutomatically(id: approval.approvalId) == nil)
            #expect(lines.all == [CloudSecretsLog.prefix + "did not answer a request from Fixture Mac" + wording])
        }
        #expect(await server.usedApprovals.isEmpty)
    }
}

/// The fixture's control, with the requests' signatures failing to load (`fail`) or not matching (`forge`).
struct SignatureReads: CloudSecretsControlPort, CloudSecretsRequestSigningPort {
    enum Mode: Sendable { case fail, forge }
    let inner: BackendCloudSecretsControl
    let mode: Mode
    func requestSignatures() async throws -> [String: String] {
        switch mode {
        case .fail: throw CloudFailure.unavailable
        case .forge:
            let real = try await inner.requestSignatures()
            return real.mapValues { _ in CloudSecretsCrypto.encode(Data(repeating: 1, count: 64)) }
        }
    }
    func signRequest(requestId: String, approvalId: String, signature: String) async throws {
        try await inner.signRequest(requestId: requestId, approvalId: approvalId, signature: signature)
    }
    func status() async throws -> CloudSecretsStatus { try await inner.status() }
    func initialize(_ request: CloudSecretsInitializeRequest) async throws -> CloudSecretsEnvelopeReceipt { try await inner.initialize(request) }
    func requestApproval(_ request: CloudApprovalRequest) async throws -> CloudApproval { try await inner.requestApproval(request) }
    func answerApproval(_ request: CloudApprovalAnswer) async throws -> CloudSecretsAnswerReceipt { try await inner.answerApproval(request) }
    func envelope() async throws -> CloudSecretsEnvelopeReceipt { try await inner.envelope() }
    func possession(_ request: CloudPossessionRequest) async throws -> CloudSecretsPossessionReceipt { try await inner.possession(request) }
    func recoveryChallenge(_ request: CloudRecoveryChallengeRequest) async throws -> CloudRecoveryChallenge { try await inner.recoveryChallenge(request) }
    func recover(_ request: CloudRecoveryCompleteRequest) async throws -> CloudSecretsEnvelopeReceipt { try await inner.recover(request) }
    func reset(_ request: CloudSecretsResetRequest) async throws -> CloudSecretsResetReceipt { try await inner.reset(request) }
    func registeredDevice(_ deviceId: String) async throws -> CloudDeviceRegistration { try await inner.registeredDevice(deviceId) }
}

/// The lines a flow wrote, in order.
final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var all: [String] { lock.withLock { lines } }
    var log: CloudSecretsLog { CloudSecretsLog { [self] line in lock.withLock { lines.append(line) } } }
}

/// A fixture passkey whose sheets follow a script: "cancel" (he closes it), "fail" (the system refuses), anything else
/// or nothing left = the real fixture passkey.
actor ScriptedPasskey: CloudSecretsPasskeyPort {
    static let failure = "the system refused the passkey (failed; on a first try Apple's copy of the domain file may not be there yet)"
    private let inner: FixturePasskey
    private var script: [String]
    var sheets = 0
    init(server: CloudSecretsFixtureServer, script: [String]) { inner = FixturePasskey(server: server); self.script = script }
    nonisolated func available() async -> Bool { true }
    func create(challenge: Data, userId: Data, userName: String, salt: Data, excluded: [Data]) async throws -> CloudSecretsPasskeyCreated {
        sheets += 1
        let next = script.isEmpty ? "ok" : script.removeFirst()
        if next == "cancel" { throw CancellationError() }
        if next == "fail" { throw CloudSecretsPlainFailure(Self.failure) }
        return try await inner.create(challenge: challenge, userId: userId, userName: userName, salt: salt, excluded: excluded)
    }
    func use(challenge: Data, allowed: [Data], salt: Data) async throws -> CloudSecretsPasskeyUsed {
        sheets += 1
        return try await inner.use(challenge: challenge, allowed: allowed, salt: salt)
    }
}
