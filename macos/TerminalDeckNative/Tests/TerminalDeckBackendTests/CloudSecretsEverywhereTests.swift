import Foundation
import Testing
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Owner, 15 Nov: "saved password and secret files ... I want them to be in cloud as well ... every small thing to be
/// synced and in everywhere." His own signed-in phones get the saved-passwords key by themselves, and the shelf carries
/// his saved passwords and project secret files SEALED for them. Fixtures only: in-memory keys, the fixture service, a
/// fake shelf service, made-up values. The phone is played by a fixture client the account lists as an iPhone: it runs
/// the very requests a phone sends (signed request, envelope, possession) against the same service shapes.
@Suite("Cloud saved passwords everywhere — his phones and the sealed shelf")
@MainActor
struct CloudSecretsEverywhereTests {
    struct Device {
        let client: CloudSecretsFixtureClient
        let graph: BackendCloudSecretsGraph
        let trust: AutoTrustBox
    }
    struct Phone {
        let client: CloudSecretsFixtureClient
        let trust: AutoTrustBox
        /// What the account lists for it (an iPhone, unless the test says otherwise).
        let registration: CloudDeviceRegistration
    }
    private func mac(_ server: CloudSecretsFixtureServer, stores: [any CloudSecretsLogicalStore] = []) async throws -> Device {
        let client = try await CloudSecretsFixtureClient(server: server)
        let box = AutoTrustBox(on: true)
        let auto = CloudSecretsAutoTrust(on: { box.isOn() }, pinned: { box.pinned($0) },
            answeredBefore: { box.answeredBefore($0, $1) }, remember: { box.remember($0, $1) })
        await client.coordinator.use(automatic: auto)
        let graph = try BackendCloudSecretsGraph(recovery: client.coordinator, content: client.content, policy: client.policy,
            local: client.local, deviceId: client.device.deviceId, outbox: AutoOutbox(), stores: stores,
            retainConflict: { _ in }, known: nil, restoreLocalStores: {}, turnsOnBySelf: true, deadAfter: 0, automatic: auto,
            pause: { ms in if ms > 5_000 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } })
        await graph.guardPresses { false }
        return Device(client: client, graph: graph, trust: box)
    }
    private func phone(_ server: CloudSecretsFixtureServer, platform: CloudPlatform = .ios) async throws -> Phone {
        let client = try await CloudSecretsFixtureClient(server: server)
        let box = AutoTrustBox(on: true)
        await client.coordinator.use(automatic: CloudSecretsAutoTrust(on: { box.isOn() }, pinned: { box.pinned($0) }))
        let own = client.device
        let listed = CloudDeviceRegistration(deviceId: own.deviceId, label: "Fixture iPhone", platform: platform, appVersion: "fixture",
                                             signPublicJwk: own.signPublicJwk, wrapPublicJwk: own.wrapPublicJwk)
        await server.register(listed)
        return Phone(client: client, trust: box, registration: listed)
    }
    private func notice(_ type: String) -> CloudEvent {
        CloudEvent(v: 1, type: type, id: UUID().uuidString.lowercased(), payload: CloudValue(.object([])))
    }
    /// The Mac pins the phone as the account listed it (a phone); the phone takes the key only from that Mac.
    private func pair(_ a: Device, _ p: Phone) {
        a.trust.trust(p.registration, name: "Fixture iPhone")
        p.trust.trust(a.client.device, name: "Studio Mac")
    }
    private func handOver(_ a: Device, _ p: Phone) async throws -> CloudApproval {
        let pending = try await p.client.coordinator.requestApproval()
        await a.graph.event(notice("approval"))
        return pending
    }

    // 1. A signed-in phone of his account gets the key with no question and no code, on either side.
    @Test func aSignedInPhoneOfHisAccountGetsTheKeyWithNoQuestion() async throws {
        for platform in [CloudPlatform.ios, .android] {
            let server = CloudSecretsFixtureServer()
            let a = try await mac(server)
            await a.graph.catchUp()
            let p = try await phone(server, platform: platform)
            pair(a, p)
            let pending = try await handOver(a, p)
            #expect(await server.requestSignatures[pending.approvalId] != nil)       // the phone signed its own request
            #expect(await server.usedApprovals.count == 1)                           // answered by the Mac by itself
            #expect(try await p.client.coordinator.receiveApproval())
            #expect(await p.client.local.value?.root == a.client.local.value?.root)
            #expect(await a.client.ui.displays.isEmpty)
            #expect(await p.client.ui.displays.isEmpty)
            #expect(await p.client.ui.transferPrompts.isEmpty)
        }
    }

    // 2. Every refused case: never answered, never shown as a sheet that could hand it over.
    // (15 Nov, later: a browser of his account is answered like a phone, as its own kind: CloudSecretsBrowserAnswerTests.)
    @Test func aRemovedDeviceAChangedKeyOrAPhoneNotPinnedHereNeverGetsIt() async throws {
        // A phone this Mac never listed (a guest, a paired-only phone, another account's device: none is on his list).
        do {
            let server = CloudSecretsFixtureServer()
            let a = try await mac(server); await a.graph.catchUp()
            let p = try await phone(server); p.trust.trust(a.client.device, name: "Studio Mac")
            _ = try await handOver(a, p)
            #expect(await server.usedApprovals.isEmpty)
            #expect(await a.graph.page().approvals.isEmpty)
        }
        // A phone the account no longer lists (signed out, removed): the service gives no keys for it.
        do {
            let server = CloudSecretsFixtureServer()
            let a = try await mac(server); await a.graph.catchUp()
            let p = try await phone(server); pair(a, p)
            _ = try await p.client.coordinator.requestApproval()
            await server.forget(p.registration.deviceId)
            await a.graph.event(notice("approval"))
            #expect(await server.usedApprovals.isEmpty)
        }
        // A phone whose signing key changed since this Mac pinned it.
        do {
            let server = CloudSecretsFixtureServer()
            let a = try await mac(server); await a.graph.catchUp()
            let p = try await phone(server)
            let other = CloudSecretsFixtureKeys()
            let earlier = CloudDeviceRegistration(deviceId: p.registration.deviceId, label: "Fixture iPhone", platform: .ios, appVersion: "fixture",
                signPublicJwk: try other.registration(p.registration.deviceId).signPublicJwk, wrapPublicJwk: p.registration.wrapPublicJwk)
            a.trust.trust(earlier, name: "Fixture iPhone"); p.trust.trust(a.client.device, name: "Studio Mac")
            _ = try await handOver(a, p)
            #expect(await server.usedApprovals.isEmpty)
        }
        // Pinned here as a phone, now listed as a Mac (or the other way round): never.
        do {
            let server = CloudSecretsFixtureServer()
            let a = try await mac(server); await a.graph.catchUp()
            let p = try await phone(server, platform: .macos)
            a.trust.trust(p.registration, name: "Fixture iPhone", platform: .ios); p.trust.trust(a.client.device, name: "Studio Mac")
            _ = try await handOver(a, p)
            #expect(await server.usedApprovals.isEmpty)
        }
    }

    // 3. "Ask me on each new device" keeps its meaning for phones: never by itself, his click with the code.
    @Test func underAskMeAPhoneWaitsForHisClickWithTheCode() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await mac(server); await a.graph.catchUp()
        _ = try await a.client.coordinator.setAskOnNewDevice(true)
        let p = try await phone(server); pair(a, p)
        let pending = try await handOver(a, p)
        #expect(await server.usedApprovals.isEmpty)
        #expect(await a.graph.page().approvals.map(\.id) == [pending.approvalId])
        try await a.client.coordinator.approve(id: pending.approvalId)
        let shown = await a.client.ui.displays
        #expect(shown.first?.matchingCode == CloudSecretsCrypto.matchingCode(pending))   // the code, to compare with the phone's
        #expect(await server.usedApprovals.count == 1)
    }

    // 4. The setting "Keep saved passwords and secret files off my phones": no phone is answered or offered, the shelf
    //    carries nothing sealed, computers are not affected.
    @Test func theSettingKeepsThemOffHisPhonesOnly() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await mac(server, stores: [AutoLogins(["one": "fixture-login-1"])]); await a.graph.catchUp()
        #expect(await a.graph.page().phonesOff == false)                                 // off by default
        await a.graph.setPhonesOff(true)
        #expect(await a.graph.page().phonesOff == true)
        let p = try await phone(server); pair(a, p)
        _ = try await handOver(a, p)
        #expect(await server.usedApprovals.isEmpty)
        #expect(await a.graph.page().approvals.isEmpty)
        if case .keptOff = await a.graph.shelfSealed() {} else { Issue.record("the sealed shelf must be kept off") }
        // Switched off again (his press): the waiting phone is answered.
        await a.graph.setPhonesOff(false)
        await a.graph.event(notice("approval"))
        #expect(await server.usedApprovals.count == 1)
        // A book that cannot be read counts as "off my phones" (fails safe).
        await a.client.local.failBookReads()
        #expect(await a.client.coordinator.phonesOff())
    }

    // 5. Saved passwords Off / locked on this Mac: nothing sealed is made, nothing is cleared.
    @Test func nothingSealedWhileSavedPasswordsAreLockedHere() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await mac(server, stores: [AutoLogins(["one": "fixture-login-1"])])
        if case .notNow = await a.graph.shelfSealed() {} else { Issue.record("no key yet: nothing may be sealed") }
        await a.graph.catchUp()
        guard case .ready(_, let records, _, let failed) = await a.graph.shelfSealed() else { Issue.record("the key is here: ready"); return }
        #expect(records.map(\.recordId) == ["one"] && failed.isEmpty)
        await a.client.local.loseKey()
        if case .notNow = await a.graph.shelfSealed() {} else { Issue.record("locked: nothing may be sealed") }
    }

    // 6. A sealed piece opens with the key, and with nothing else.
    @Test func aSealedPieceOpensWithTheKeyAndNothingElse() throws {
        let root = Data(repeating: 7, count: 32), sub = CloudSecretsFixtureServer.sub
        let sealer = try CloudSecretsShelfSealer.make(root: root, sub: sub, epoch: 3)
        let id = UUID().uuidString.lowercased()
        let piece = try sealer.seal(Data("fixture-secret-4b7e".utf8), kind: .savedPasswords, role: .value, pieceId: id)
        #expect(try sealer.open(piece, kind: .savedPasswords, role: .value) == Data("fixture-secret-4b7e".utf8))
        // Another key, another account, another generation, the other kind, the other role: all refused.
        for other in [try CloudSecretsShelfSealer.make(root: Data(repeating: 8, count: 32), sub: sub, epoch: 3),
                      try CloudSecretsShelfSealer.make(root: root, sub: "22222222-2222-4222-8222-222222222222", epoch: 3)] {
            #expect(throws: (any Error).self) { try other.open(piece, kind: .savedPasswords, role: .value) }
        }
        let later = try CloudSecretsShelfSealer.make(root: root, sub: sub, epoch: 4)
        #expect(throws: (any Error).self) { try later.open(piece, kind: .savedPasswords, role: .value) }
        #expect(throws: (any Error).self) { try sealer.open(piece, kind: .projectSecretFiles, role: .value) }
        #expect(throws: (any Error).self) { try sealer.open(piece, kind: .savedPasswords, role: .index) }
        // The service moves the sealed bytes under another piece id, or relabels the kind: refused.
        let moved = CloudSecretsShelfSeal.Piece(v: 1, suite: piece.suite, kind: .savedPasswords, role: .value, epoch: 3,
            pieceId: UUID().uuidString.lowercased(), nonce: piece.nonce, ciphertext: piece.ciphertext, tag: piece.tag)
        #expect(throws: (any Error).self) { try sealer.open(moved, kind: .savedPasswords, role: .value) }
        let relabelled = CloudSecretsShelfSeal.Piece(v: 1, suite: piece.suite, kind: .projectSecretFiles, role: .value, epoch: 3,
            pieceId: id, nonce: piece.nonce, ciphertext: piece.ciphertext, tag: piece.tag)
        #expect(throws: (any Error).self) { try sealer.open(relabelled, kind: .projectSecretFiles, role: .value) }
        // Padding: a short value and a longer one have the same sealed size.
        let short = try sealer.seal(Data("a".utf8), kind: .savedPasswords, role: .value, pieceId: UUID().uuidString.lowercased())
        let longer = try sealer.seal(Data(String(repeating: "b", count: 200).utf8), kind: .savedPasswords, role: .value, pieceId: UUID().uuidString.lowercased())
        #expect(short.ciphertext.count == longer.ciphertext.count)
    }

    /// Made-up records of the three shapes: an API key (generic), an MCP server sign-in and a project secret file.
    private func records() throws -> [CloudSecretRecord] {
        let file = NativeRPCValue.object([.init("v", .number(1)), .init("projectId", .string("fixture-project")), .init("folder", .string("")),
            .init("path", .string("config/fixture-secret.env")), .init("mode", .number(384)),
            .init("data", .string(Data("FIXTURE_DB=fixture-db-pass-55aa".utf8).base64EncodedString())), .init("mark", .string("fixture-mark")),
            .init("at", .number(1_800_000_000_000)), .init("from", .string("Studio Mac"))])
        return [
            CloudSecretRecord(sourceId: "api", recordId: "fixture-api", domain: CloudSecretsDomain.apiKey.rawValue, payload: .init(Self.apiValue("Fixture API", key: "fixture-api-key-31f0"))),
            CloudSecretRecord(sourceId: "mcp-user", recordId: "Fixture Notes Server", domain: CloudSecretsDomain.mcp.rawValue,
                payload: .init(.object([.init("definition", .object([.init("command", .string("npx")),
                    .init("env", .object([.init("FIXTURE_TOKEN", .string("fixture-token-71c2"))]))]))]))),
            CloudSecretRecord(sourceId: BackendProjectSecretFilesRules.sourceId, recordId: "file/fixture-project/abc", domain: CloudSecretsDomain.project.rawValue,
                payload: .init(file))
        ]
    }

    /// An "api" record as keys-travel writes it (BackendCloudKeysAPIValue), so the shelf reads it.
    nonisolated static func apiValue(_ name: String, key: String) -> NativeRPCValue {
        .object([.init("name", .string(name)), .init("provider", .string("claude")), .init("kind", .string("anthropic")),
                 .init("baseURL", .string("https://api.example.test")), .init("key", .string(key))])
    }

    // 7. What the service can see holds no name and no value; the phone opens everything with the key.
    @Test func theOutsideHoldsNoNameAndNoValue() throws {
        let sealer = try CloudSecretsShelfSealer.make(root: Data(repeating: 9, count: 32), sub: CloudSecretsFixtureServer.sub, epoch: 1)
        let items = BackendCloudShelfSealed.items(try records(), projectNames: ["fixture-project": "Fixture Garden"])
        #expect(items[.savedPasswords]?.count == 2 && items[.projectSecretFiles]?.count == 1)
        var outside = ""
        for kind in CloudSecretsShelfSeal.Kind.allCases {
            let made = try BackendCloudShelfSealed.pieces(kind, items: items[kind] ?? [], sealer: sealer, putId: UUID().uuidString.lowercased(),
                                                          madeAt: 1, madeBy: "Studio Mac")
            outside += String(decoding: try JSONEncoder().encode(made.index + made.values), as: UTF8.self) + made.fingerprint
            // The phone's side: the list opens, and each value opens by itself.
            let list = try JSONDecoder().decode(CloudSecretsShelfSeal.Index.self, from: try sealer.open(made.index[0], kind: kind, role: .index))
            #expect(list.count == (kind == .savedPasswords ? 2 : 1))
            if kind == .savedPasswords {
                let mcp = try #require(list.passwords?.first { $0.name == "Fixture Notes Server" })
                #expect(mcp.purpose == "MCP server")
                let piece = try #require(made.values.first { $0.pieceId == mcp.value })
                let value = try JSONDecoder().decode(CloudSecretsShelfSeal.Value.self, from: try sealer.open(piece, kind: kind, role: .value))
                #expect(value.fields.contains { $0.label == "env.FIXTURE_TOKEN" && $0.value == "fixture-token-71c2" && $0.secret })
                #expect(value.fields.contains { $0.label == "command" && !$0.secret })
            } else {
                let file = try #require(list.files?.first)
                #expect(file.project == "Fixture Garden" && file.file == "fixture-secret.env" && file.place == "config/fixture-secret.env")
                let piece = try #require(made.values.first { $0.pieceId == file.value })
                #expect(try sealer.open(piece, kind: kind, role: .value) == Data("FIXTURE_DB=fixture-db-pass-55aa".utf8))
            }
        }
        for secret in ["fixture-api-key-31f0", "fixture-token-71c2", "fixture-db-pass-55aa", "Fixture Notes Server", "FIXTURE_TOKEN",
                       "Fixture Garden", "fixture-secret.env", "config/", "fixture-project", "Studio Mac", "MCP server", "API key",
                       Data("FIXTURE_DB=fixture-db-pass-55aa".utf8).base64EncodedString()] {
            #expect(!outside.contains(secret))
        }
    }

    // 8. Only what changed goes up again; a crash between the pieces and the list resumes by itself.
    @Test func onlyWhatChangedGoesUpAndAnInterruptedPutResumes() async throws {
        let sealer = try CloudSecretsShelfSealer.make(root: Data(repeating: 5, count: 32), sub: CloudSecretsFixtureServer.sub, epoch: 1)
        let service = FakeSealedShelf()
        let putter = BackendCloudShelfSealedPutter(send: { try await service.handle($0, $1, $2) }, file: nil)
        func made(_ logins: [String: String]) throws -> BackendCloudShelfSealed.Pieces {
            let records = logins.sorted { $0.key < $1.key }.map { CloudSecretRecord(sourceId: "api", recordId: $0.key, domain: CloudSecretsDomain.apiKey.rawValue,
                payload: .init(Self.apiValue($0.key, key: $0.value))) }
            return try BackendCloudShelfSealed.pieces(.savedPasswords, items: BackendCloudShelfSealed.items(records, projectNames: [:])[.savedPasswords] ?? [],
                                                      sealer: sealer, putId: UUID().uuidString.lowercased(), madeAt: 1, madeBy: "Studio Mac")
        }
        #expect(await putter.put(try made(["one": "fixture-1", "two": "fixture-2"]), epoch: 1, throughSeq: "5") == .put(count: 2, pieces: 2))
        #expect(await putter.put(try made(["one": "fixture-1", "two": "fixture-2"]), epoch: 1, throughSeq: "6") == .unchanged)
        #expect(await putter.put(try made(["one": "fixture-1", "two": "fixture-2b"]), epoch: 1, throughSeq: "7") == .put(count: 2, pieces: 1))
        #expect(await service.stored.count == 2)                                         // the replaced value was swept
        // The list call is lost after its pieces went up: the next round sends no piece again, only the list.
        await service.loseNextIndex()
        #expect(await putter.put(try made(["one": "fixture-1c", "two": "fixture-2b"]), epoch: 1, throughSeq: "8") == .later)
        #expect(await putter.put(try made(["one": "fixture-1c", "two": "fixture-2b"]), epoch: 1, throughSeq: "8") == .put(count: 2, pieces: 0))
        // His phones setting: both kinds leave the shelf, once.
        #expect(await putter.clear() == .cleared)
        #expect(await putter.clear() == .unchanged)
        #expect(await service.stored.isEmpty)
    }
}

extension CloudSecretsEverywhereTests {
    private func sealedRig(file: URL? = nil) throws -> (CloudSecretsShelfSealer, FakeSealedShelf, BackendCloudShelfSealedPutter, SealedMaterialBox, SealedNotes, SealedClock) {
        let sealer = try CloudSecretsShelfSealer.make(root: Data(repeating: 3, count: 32), sub: CloudSecretsFixtureServer.sub, epoch: 1)
        let service = FakeSealedShelf()
        return (sealer, service, BackendCloudShelfSealedPutter(send: { try await service.handle($0, $1, $2) }, file: file),
                SealedMaterialBox(), SealedNotes(), SealedClock())
    }
    private func round(_ putter: BackendCloudShelfSealedPutter, _ feed: SealedMaterialBox, _ sealer: CloudSecretsShelfSealer,
                       _ notes: SealedNotes, _ clock: SealedClock) -> BackendCloudShelfSealedRound {
        BackendCloudShelfSealedRound(putter: putter, material: { feed.material(sealer) }, note: { notes.add($0) }, clock: { clock.now })
    }

    // 11 (review S1). While API keys cannot be read, an entry he removed from a source that reads fine leaves his phones.
    @Test func aRemovedEntryOfAReadableSourceLeavesHisPhonesWhileAnotherSourceFails() async throws {
        let (sealer, service, putter, feed, notes, clock) = try sealedRig()
        let r = round(putter, feed, sealer, notes, clock)
        feed.set(records: Self.twoSources(), failed: [:])
        _ = await r.run(throughSeq: "1", from: nil, atLaunch: true, signal: ["1"])
        #expect(await service.stored.count == 2)
        // The MCP server is removed (its source reads, now empty) while API keys cannot be read.
        feed.set(records: [], failed: ["api": "not ready yet on this Mac"])
        clock.now += 1_000
        _ = await r.run(throughSeq: "2", from: nil, atLaunch: false, signal: ["2"])
        clock.now += BackendCloudShelf.settleMs
        _ = await r.run(throughSeq: "2", from: nil, atLaunch: false, signal: ["2"])
        #expect(notes.lines.last?.contains("saved passwords: put 1") == true)
        #expect(await service.stored.count == 1)                                   // the MCP server's value was swept
        #expect(await putter.state.kinds["savedPasswords"]?.sources == ["api"])    // the API key is still on his phones
    }

    // 12 (review S1). After a restart (no lines in memory) the kind is kept as it is; after 24 hours of failing the list
    // goes up without that source, and the time is cleared once it leaves the list.
    @Test func aSourceThatFailsForADayIsLeftOutAfter24Hours() async throws {
        let (sealer, service, putter, feed, notes, clock) = try sealedRig()
        feed.set(records: Self.twoSources(), failed: [:])
        _ = await round(putter, feed, sealer, notes, clock).run(throughSeq: "1", from: nil, atLaunch: true, signal: ["1"])
        let restarted = round(putter, feed, sealer, notes, clock)
        feed.set(records: Array(Self.twoSources().dropFirst()), failed: ["api": "not ready yet on this Mac"])
        _ = await restarted.run(throughSeq: "2", from: nil, atLaunch: true, signal: ["2"])
        #expect(notes.lines.last?.contains("kept as on your phones until API keys can be read") == true)
        #expect(await service.stored.count == 2)
        #expect(await putter.state.kinds["savedPasswords"]?.failingSince?["api"] == clock.now)
        clock.now += BackendCloudShelf.dayMs
        _ = await restarted.run(throughSeq: "3", from: nil, atLaunch: false, signal: ["3"])
        clock.now += BackendCloudShelf.settleMs
        _ = await restarted.run(throughSeq: "3", from: nil, atLaunch: false, signal: ["3"])
        #expect(notes.lines.contains { $0.contains("left out after 24 hours: API keys") })
        #expect(await service.stored.count == 1)
        #expect(await putter.state.kinds["savedPasswords"]?.sources == ["mcp-user"])
        clock.now += 1_000
        _ = await restarted.run(throughSeq: "4", from: nil, atLaunch: false, signal: ["4"])
        #expect(await putter.state.kinds["savedPasswords"]?.failingSince == nil)
    }

    // 13 (review S2). A list was put before but this Mac's memory names no sources (an older state file): a failed
    // source counts as shown and the kind is kept. Nothing ever put: the readable sources go up.
    @Test func unknownSourcesKeepTheKindAndNothingEverPutPutsWhatReads() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sealed-s2-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("shelf-sealed.json")
        try Data(#"{"kinds":{"savedPasswords":{"fingerprint":"older","epoch":1,"putAt":1800000000000}},"cleared":false}"#.utf8).write(to: file)
        let (sealer, service, putter, feed, notes, clock) = try sealedRig(file: file)
        feed.set(records: Array(Self.twoSources().dropFirst()), failed: ["api": "not ready yet on this Mac"])
        _ = await round(putter, feed, sealer, notes, clock).run(throughSeq: "1", from: nil, atLaunch: true, signal: ["1"])
        #expect(await service.index["savedPasswords"] == nil)
        #expect(notes.lines.last?.contains("saved passwords: kept as on your phones until API keys can be read") == true)
        // Never put on this account: what reads goes up at once.
        let (sealer2, service2, putter2, feed2, notes2, clock2) = try sealedRig()
        feed2.set(records: Array(Self.twoSources().dropFirst()), failed: ["api": "not ready yet on this Mac"])
        _ = await round(putter2, feed2, sealer2, notes2, clock2).run(throughSeq: "1", from: nil, atLaunch: true, signal: ["1"])
        #expect(await service2.stored.count == 1)
        #expect(notes2.lines.last?.contains("saved passwords: put 1") == true)
    }

    // 9 (15 Nov fix). One source that cannot be read leaves the others readable: it is named, it does not stop the round.
    @Test func oneSourceThatCannotBeReadLeavesTheOthersOnTheList() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await mac(server, stores: [AutoLogins(["one": "fixture-login-1"]), SealedFailingStore()])
        await a.graph.catchUp()
        guard case .ready(_, let records, _, let failed) = await a.graph.shelfSealed() else { Issue.record("the key is here: ready"); return }
        #expect(records.map(\.recordId) == ["one"])
        #expect(failed == ["tasks": "could not be read"])
    }

    /// Made-up records of two sources: an API key and an MCP server sign-in.
    nonisolated static func twoSources(apiKey: String = "fixture-api-key-31f0") -> [CloudSecretRecord] {
        [CloudSecretRecord(sourceId: "api", recordId: "fixture-api", domain: CloudSecretsDomain.apiKey.rawValue, payload: .init(apiValue("Fixture API", key: apiKey))),
         CloudSecretRecord(sourceId: "mcp-user", recordId: "Fixture Notes Server", domain: CloudSecretsDomain.mcp.rawValue,
            payload: .init(.object([.init("definition", .object([.init("command", .string("npx")),
                .init("env", .object([.init("FIXTURE_TOKEN", .string("fixture-token-71c2"))]))]))])))]
    }

    // 10 (15 Nov fix). A failed read never takes off his phones what they show; a source never shown is just left out;
    // each outcome is one log line with no name and no value; the failure is tried again 30 s later.
    @Test func aFailedReadKeepsWhatHisPhonesShowAndTheLogLineNamesNothingOfHis() async throws {
        let sealer = try CloudSecretsShelfSealer.make(root: Data(repeating: 6, count: 32), sub: CloudSecretsFixtureServer.sub, epoch: 1)
        let service = FakeSealedShelf()
        let putter = BackendCloudShelfSealedPutter(send: { try await service.handle($0, $1, $2) }, file: nil)
        let feed = SealedMaterialBox(), notes = SealedNotes(), clock = SealedClock()
        let round = BackendCloudShelfSealedRound(putter: putter, material: { feed.material(sealer) }, note: { notes.add($0) }, clock: { clock.now })
        // Both read: both up.
        feed.set(records: Self.twoSources(), failed: [:])
        #expect(await round.run(throughSeq: "1", from: "Studio Mac", atLaunch: true, signal: ["1"]))
        #expect(await service.stored.count == 2)
        let shown = await service.index["savedPasswords"]
        #expect(await putter.state.kinds["savedPasswords"]?.sources == ["api", "mcp-user"])
        // API keys cannot be read now: the list his phones show stays exactly as it is.
        feed.set(records: Array(Self.twoSources().dropFirst()), failed: ["api": "not ready yet on this Mac"])
        clock.now += 1_000
        #expect(await round.run(throughSeq: "2", from: "Studio Mac", atLaunch: false, signal: ["2"]))
        #expect(await service.stored.count == 2)
        #expect(await service.index["savedPasswords"] == shown)
        #expect(notes.lines.last?.contains("saved passwords: last entries carried for API keys") == true)
        #expect(notes.lines.last?.contains("saved passwords: unchanged") == true)
        #expect(notes.lines.last?.contains("not read this round: API keys (not ready yet on this Mac)") == true)
        #expect(await round.retryAt == clock.now + BackendCloudShelf.settleMs)
        // Read again: the changed value goes up (after its settle), nothing was ever dropped.
        feed.set(records: Self.twoSources(apiKey: "fixture-api-key-changed"), failed: [:])
        clock.now += BackendCloudShelf.settleMs
        #expect(await round.retryDue())
        _ = await round.run(throughSeq: "3", from: "Studio Mac", atLaunch: false, signal: ["3"])
        clock.now += BackendCloudShelf.settleMs
        _ = await round.run(throughSeq: "3", from: "Studio Mac", atLaunch: false, signal: ["3"])
        #expect(notes.lines.last?.contains("saved passwords: put 2") == true)
        // The same outcome twice is one line, and no line carries a name, a place or a value of his.
        clock.now += 1_000
        _ = await round.run(throughSeq: "4", from: "Studio Mac", atLaunch: false, signal: ["4"])
        let count = notes.lines.count
        clock.now += 1_000
        _ = await round.run(throughSeq: "5", from: "Studio Mac", atLaunch: false, signal: ["5"])
        #expect(notes.lines.count == count)
        for line in notes.lines {
            for secret in ["fixture-api-key", "fixture-token-71c2", "Fixture API", "Fixture Notes Server", "FIXTURE_TOKEN", "Studio Mac", "npx"] {
                #expect(!line.contains(secret))
            }
        }
    }
}

/// A saved-passwords source that cannot be read (fixture).
final class SealedFailingStore: CloudSecretsLogicalStore, @unchecked Sendable {
    let sourceId = "tasks"
    let inventoryRow = "I16"
    let domain = CloudSecretsDomain.taskConnection
    func capture() async throws -> [CloudSecretRecord] { throw CloudFailure.unavailable }
    func validate(_ record: CloudSecretRecord) async throws {}
    func merge(_ record: CloudSecretRecord) async throws -> CloudApplyStatus { .alreadyPresent }
    func verify(_ record: CloudSecretRecord, outcome: CloudApplyStatus) async throws -> Bool { true }
}
/// What the saved-passwords owner hands the round (fixture).
final class SealedMaterialBox: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [CloudSecretRecord] = []
    private var failed: [String: String] = [:]
    func set(records: [CloudSecretRecord], failed: [String: String]) { lock.withLock { self.records = records; self.failed = failed } }
    func material(_ sealer: CloudSecretsShelfSealer) -> BackendCloudSecretsGraph.ShelfSealed {
        lock.withLock { .ready(sealer: sealer, records: records, projectNames: [:], failed: failed) }
    }
}
final class SealedNotes: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [String] = []
    func add(_ line: String) { lock.withLock { held.append(line) } }
    var lines: [String] { lock.withLock { held } }
}
final class SealedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var at: Int64 = 1_800_000_000_000
    var now: Int64 { get { lock.withLock { at } } set { lock.withLock { at = newValue } } }
}

extension CloudSecretsFixtureLocal {
    func failBookReads() { failBook = true }
}

/// The Servers contract's sealed routes, as a fake: it stores pieces it cannot open, by id, and sweeps unnamed values.
actor FakeSealedShelf {
    var stored: [String: Data] = [:]
    /// Each stored piece's kind: a list sweeps only its own kind's pieces (as the service does).
    var kindOf: [String: String] = [:]
    var index: [String: Data] = [:]
    var loseIndex = false
    func loseNextIndex() { loseIndex = true }
    func handle(_ method: String, _ path: String, _ body: Data) throws -> (status: Int, data: Data) {
        let raw = try NativeRPCValue.parseJSON(body)
        switch path {
        case "/shelf/sealed/missing":
            let ids = (raw["pieceIds"].elements ?? []).compactMap(\.string)
            return (200, try JSONEncoder().encode(["missing": ids.filter { stored[$0] == nil }]))
        case "/shelf/sealed/pieces":
            for piece in raw["pieces"].elements ?? [] {
                guard let id = piece["pieceId"].string, piece["role"].string == "value" else { return (400, Data()) }
                stored[id] = try JSONEncoder().encode(CloudValue(piece)); kindOf[id] = raw["kind"].string ?? "-"
            }
            return (200, Data("{}".utf8))
        case "/shelf/sealed/index":
            if loseIndex { loseIndex = false; throw CloudFailure.unavailable }
            let named = Set((raw["valueIds"].elements ?? []).compactMap(\.string))
            guard named.isSubset(of: Set(stored.keys)) else { return (409, Data(#"{"error":{"code":"pieces_missing"}}"#.utf8)) }
            let kind = raw["kind"].string ?? ""
            stored = stored.filter { named.contains($0.key) || kindOf[$0.key] != kind }
            index[raw["kind"].string ?? ""] = body
            return (200, Data(#"{"accepted":true,"asOf":1}"#.utf8))
        case "/shelf/sealed/clear":
            stored = [:]; index[raw["kind"].string ?? ""] = nil
            return (200, Data("{}".utf8))
        default:
            return (404, Data())
        }
    }
}
