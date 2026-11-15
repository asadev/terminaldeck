import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// MAC-NEXT-10: one row per machine. Each Mac tells the service a stable machine id (a hash of hardware id + account)
/// and its friendly name, at registration and once at launch, and never anything that reveals the hardware id.
final class CloudMachineFactsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var mark: String?
    private var name: String
    private var remembered = 0
    let hardware: String
    init(hardware: String = "0F3A9C2E-1B44-4C1D-9E77-ABCDEF012345", name: String = "Studio Mac mini") { self.hardware = hardware; self.name = name }
    func setName(_ value: String) { lock.withLock { name = value } }
    func remembers() -> Int { lock.withLock { remembered } }
    func storedMark() -> String? { lock.withLock { mark } }
    func facts() -> BackendCloudMachineFacts {
        .init(hardwareUUID: { self.hardware }, computerName: { self.lock.withLock { self.name } },
              accepted: { self.lock.withLock { self.mark } }, remember: { m in self.lock.withLock { self.mark = m; self.remembered += 1 } })
    }
}

@Suite("Cloud machine identity — one row per machine")
struct CloudMachineIdentityTests {
    static let subjectA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    static let subjectB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    func relaunch(_ f: CloudAccountFixture, _ box: CloudMachineFactsBox) -> BackendCloudAccount {
        BackendCloudAccount(configuration: f.identity.configuration, identity: f.identity, http: f.server, transport: f.transport, outbox: f.outbox,
                            trust: f.trust, clock: { f.clock.now() }, monotonic: { f.clock.monotonic() }, machine: box.facts())
    }
    func settle(_ until: @escaping () async -> Bool) async {
        for _ in 0..<200 where !(await until()) { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func idIsStablePerMachineAndAccountAndRevealsNoHardwareId() throws {
        let hardware = "0F3A9C2E-1B44-4C1D-9E77-ABCDEF012345"
        let a = try #require(BackendCloudMachineFacts.machineId(hardwareUUID: hardware, subject: Self.subjectA))
        #expect(a.count == 32 && a.allSatisfy { $0.isHexDigit })
        #expect(BackendCloudMachineFacts.machineId(hardwareUUID: hardware.lowercased(), subject: Self.subjectA) == a)
        #expect(BackendCloudMachineFacts.machineId(hardwareUUID: hardware, subject: Self.subjectB) != a)
        #expect(BackendCloudMachineFacts.machineId(hardwareUUID: "11111111-2222-4333-8444-555555555555", subject: Self.subjectA) != a)
        #expect(BackendCloudMachineFacts.machineId(hardwareUUID: hardware, subject: Self.subjectA, copy: "Terminal Deck Dev") != a)
        let plain = hardware.lowercased().replacingOccurrences(of: "-", with: "")
        for piece in stride(from: 0, to: plain.count - 8, by: 4) {
            let start = plain.index(plain.startIndex, offsetBy: piece)
            #expect(!a.contains(plain[start..<plain.index(start, offsetBy: 8)]))
        }
        let pair = try #require(CloudMachineFactsBox(hardware: hardware).facts().pair(subject: Self.subjectA))
        let mark = BackendCloudMachineFacts.mark(deviceId: "d", pair)
        #expect(!mark.uppercased().contains(hardware.replacingOccurrences(of: "-", with: "")) && !mark.contains(plain))
    }

    @Test func dataFolderSeparatesCopiesAndTheReleasedAppKeepsItsId() throws {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let standard = home.appendingPathComponent("Library/Application Support/terminaldeck", isDirectory: true)
        let released = BackendCloudMachineFacts.copyName(appName: "Terminal Deck", dataRoot: standard, home: home)
        #expect(released == "")
        let hardware = "0F3A9C2E-1B44-4C1D-9E77-ABCDEF012345"
        let before = BackendCloudMachineFacts.machineId(hardwareUUID: hardware, subject: Self.subjectA)
        #expect(BackendCloudMachineFacts.machineId(hardwareUUID: hardware, subject: Self.subjectA, copy: released) == before)
        #expect(BackendCloudMachineFacts.copyName(appName: "Terminal Deck Dev", dataRoot: standard, home: home) == "Terminal Deck Dev")
        let one = BackendCloudMachineFacts.copyName(appName: "Terminal Deck", dataRoot: URL(fileURLWithPath: "/tmp/td-proof-1"), home: home)
        let two = BackendCloudMachineFacts.copyName(appName: "Terminal Deck", dataRoot: URL(fileURLWithPath: "/tmp/td-proof-2"), home: home)
        #expect(!one.isEmpty && one != two && !one.contains("td-proof"))
        #expect(BackendCloudMachineFacts.copyName(appName: "Terminal Deck", dataRoot: URL(fileURLWithPath: "/tmp/td-proof-1"), home: home) == one)
        let idOne = BackendCloudMachineFacts.machineId(hardwareUUID: hardware, subject: Self.subjectA, copy: one)
        let idTwo = BackendCloudMachineFacts.machineId(hardwareUUID: hardware, subject: Self.subjectA, copy: two)
        #expect(idOne != idTwo && idOne != before && idTwo != before)
    }

    @Test func aServiceThatLostTheNameGetsItAgainAtLaunch() async throws {
        let f = try CloudAccountFixture.make(), box = CloudMachineFactsBox()
        await f.server.setMachineService(.knows)
        await f.account.setMachineFacts(box.facts())
        _ = try await f.signin()
        #expect(box.remembers() == 1)
        await f.server.forgetDisplayName()
        try await relaunch(f, box).resume()
        await settle { await f.server.describeCalls.count == 1 }
        #expect(await f.server.describeCalls.count == 1 && box.remembers() == 2)
    }

    @Test func friendlyNameIsTrimmedCutAndFallsBack() {
        #expect(BackendCloudMachineFacts.displayName("  Studio Mac mini \n") == "Studio Mac mini")
        #expect(BackendCloudMachineFacts.displayName(String(repeating: "é", count: 90)).utf16.count == 64)
        #expect(BackendCloudMachineFacts.displayName("   ") == "Mac")
        #expect(BackendCloudMachineFacts.hostWithoutLocal("imatch-mac-mini.local") == "imatch-mac-mini")
    }

    @Test func registrationCarriesBothFieldsAndIdSurvivesSignOutAndIn() async throws {
        let f = try CloudAccountFixture.make(), box = CloudMachineFactsBox()
        await f.server.setMachineService(.knows)
        await f.account.setMachineFacts(box.facts())
        _ = try await f.signin()
        let first = try #require(await f.server.registrationBodies.last)
        let expected = BackendCloudMachineFacts.machineId(hardwareUUID: box.hardware, subject: Self.subjectA)
        #expect(first.machineId == expected && first.displayName == "Studio Mac mini" && first.hostName == "Fixture Mac")
        #expect(box.remembers() == 1)
        // The JSON on the wire carries both fields and nothing hardware-shaped.
        let body = String(decoding: try CloudWire.canonical(first), as: UTF8.self)
        #expect(body.contains("\"machineId\"") && body.contains("\"displayName\"") && body.contains("\"hostName\"") && !body.uppercased().contains(box.hardware))
        // Signed out and in again: a new device id, the same machine id.
        try await f.account.signOut()
        _ = try await f.signin()
        let second = try #require(await f.server.registrationBodies.last)
        #expect(second.deviceId != first.deviceId && second.machineId == first.machineId)
        // Rows show the friendly name the service returns.
        let rows = await f.account.state().trust
        #expect(rows.contains { $0.standing == .thisMac && $0.name == "Studio Mac mini" })
        #expect(await f.server.describeCalls.isEmpty)
    }

    @Test func alreadyRegisteredMacSendsOnceAtLaunchAndNotAgain() async throws {
        let f = try CloudAccountFixture.make()
        _ = try await f.signin()                 // an older app: registered without the fields
        #expect(await f.server.registrationBodies.last?.machineId == nil)
        await f.server.setMachineService(.knows)
        let box = CloudMachineFactsBox()
        let launch = relaunch(f, box)
        try await launch.resume()
        await settle { await f.server.describeCalls.count == 1 && box.remembers() == 1 }
        let call = try #require(await f.server.describeCalls.first)
        #expect(call.machineId == BackendCloudMachineFacts.machineId(hardwareUUID: box.hardware, subject: Self.subjectA))
        #expect(call.displayName == "Studio Mac mini" && call.label == "Fixture Mac" && call.hostName == "Fixture Mac")
        try await launch.refresh()               // later status reads in the same run send nothing
        let again = relaunch(f, box)             // the next launch: nothing changed, nothing sent
        try await again.resume()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await f.server.describeCalls.count == 1)
        box.setName("Studio")                    // the name changed: sent once more
        let renamed = relaunch(f, box)
        try await renamed.resume()
        await settle { await f.server.describeCalls.count == 2 }
        #expect(await f.server.describeCalls.last?.displayName == "Studio")
    }

    @Test func refusingOrIgnoringServiceChangesNothingElse() async throws {
        // Refuses unknown fields: sign-in still finishes with a plain registration.
        let f = try CloudAccountFixture.make(), box = CloudMachineFactsBox()
        await f.server.setMachineService(.refuses)
        await f.account.setMachineFacts(box.facts())
        _ = try await f.signin()
        #expect(await f.account.state().phase == .signedIn)
        let bodies = await f.server.registrationBodies
        #expect(bodies.count == 3 && bodies[0].hostName != nil && bodies[1].machineId != nil && bodies[1].hostName == nil
                && bodies[2].machineId == nil && bodies[2].displayName == nil && bodies[2].hostName == nil)
        #expect(box.remembers() == 0)
        // Launch: the refused self-description is one quiet failure; status and pages carry on; tried again next launch.
        let launch = relaunch(f, box)
        try await launch.resume()
        // (with the host name, then without it: both refused)
        await settle { await f.server.describeCalls.count == 2 }
        #expect(await launch.state().phase == .signedIn && box.remembers() == 0)
        try await relaunch(f, box).resume()
        await settle { await f.server.describeCalls.count == 4 }
        #expect(await f.server.describeCalls.count == 4)
        // Ignores the fields: sign-in fine, nothing remembered, rows keep the recorded label.
        let g = try CloudAccountFixture.make(), other = CloudMachineFactsBox()
        await g.account.setMachineFacts(other.facts())
        _ = try await g.signin()
        #expect(await g.account.state().phase == .signedIn && other.remembers() == 0)
        #expect(await g.account.state().trust.contains { $0.standing == .thisMac && $0.name == "Fixture Mac" })
        #expect(await g.transport.registrations == 1)
    }

    // MAC-NEXT-11: a Mac that sent id + friendly name on ed50f277 (its remembered mark has no host name) sends once more
    // with the host name; a service that refuses only the host name still gets the id and the name, nothing breaks.
    @Test func hostNameIsSentOnceMoreAndARefusalOfItCostsNothing() async throws {
        let f = try CloudAccountFixture.make(), box = CloudMachineFactsBox()
        _ = try await f.signin()
        await f.server.setMachineService(.knows)
        let deviceId = try await f.identity.deviceRegistration().deviceId
        let old = try #require(box.facts().pair(subject: Self.subjectA))      // what ed50f277 remembered: no host name
        box.facts().remember(BackendCloudMachineFacts.mark(deviceId: deviceId, old))
        try await relaunch(f, box).resume()
        await settle { await f.server.describeCalls.count == 1 && box.remembers() == 2 }
        #expect(await f.server.describeCalls.first?.hostName == "Fixture Mac" && box.remembers() == 2)
        try await relaunch(f, box).resume()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await f.server.describeCalls.count == 1)
        // Refuses the host name: registration falls back to id + name (no plain loss), launch sends id + name.
        let g = try CloudAccountFixture.make(), other = CloudMachineFactsBox()
        await g.server.setMachineService(.noHost)
        await g.account.setMachineFacts(other.facts())
        _ = try await g.signin()
        let bodies = await g.server.registrationBodies
        #expect(bodies.count == 2 && bodies[1].machineId != nil && bodies[1].hostName == nil && other.remembers() == 1)
        #expect(await g.account.state().phase == .signedIn)
        try await relaunch(g, other).resume()
        await settle { await g.server.describeCalls.count == 2 }
        let calls = await g.server.describeCalls
        #expect(calls.count == 2 && calls[0].hostName == "Fixture Mac" && calls[1].hostName == nil && calls[1].machineId == bodies[1].machineId)
    }
}
