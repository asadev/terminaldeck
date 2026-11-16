import Foundation
import SwiftUI
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// The Devices window's tools (owner, 13 Nov: every feature ships with its tools): devices_page answers the same rows
/// the window shows; devices_remove does what the old Remove did; nothing they say names the old way; reading the page
/// never writes a record of the old way.
@MainActor
final class DevicesPageToolsTests: XCTestCase {
    typealias V = NativeRPCValue
    nonisolated static let now = Date().timeIntervalSince1970 * 1000

    actor Spy {
        var channels: [(String, [V])] = []
        var owners: [Bool] = []
        func note(_ channel: String, _ args: [V]) { channels.append((channel, args)) }
        func asked(_ owner: Bool) { owners.append(owner) }
        var signedOut: [String] = []
        var refusal: BackendDeviceSignOutRefusal?
        func signOut(_ id: String) throws { if let refusal { throw refusal }; signedOut.append(id) }
        func refuse(_ refusal: BackendDeviceSignOutRefusal?) { self.refusal = refusal }
        var names: [String] { channels.map(\.0) }
        var renamed: [(String, String)] = []
        func rename(_ id: String, _ name: String) { renamed.append((id, name)) }
    }

    /// His old entries: an iPhone seen 17 minutes ago, a browser connected now, an emulator seen 20 days ago.
    nonisolated static func answer(_ channel: String) -> V {
        switch channel {
        case "remote:status":
            return .object([.init("running", .bool(true)), .init("connections", .array([.object([.init("id", .string("c1")), .init("deviceId", .string("b1")),
                .init("deviceName", .string("Chrome on Mac")), .init("platform", .string("web"))])]))])
        case "remote:devices":
            func row(_ id: String, _ name: String, _ seen: Double) -> V {
                .object([.init("id", .string(id)), .init("name", .string(name)), .init("status", .string("approved")),
                         .init("addedAt", .number(now - 40 * 86_400_000)), .init("lastSeenAt", .number(seen)), .init("fingerprint", .string("AB:CD"))])
            }
            return .array([row("p1", "iPhone", now - 17 * 60_000), row("b1", "Chrome on Mac", now - 3_600_000), row("e1", "Android emulator", now - 20 * 86_400_000)])
        case "machines:list":
            return .object([.init("machines", .array([])), .init("links", .array([]))])
        default:
            return .array([])
        }
    }

    func tools(_ spy: Spy, signedIn: Bool = true, entitled: Bool? = true, caller: BackendDeckToolsAppCaller.Kind = .local,
               twins: Bool = false,
               answer: @escaping @Sendable (String) -> V = { DevicesPageToolsTests.answer($0) }) throws -> [BackendDeckToolsDefinition] {
        let access = BackendDeckToolsAppAccess(caller: { _ in .init(kind: caller) }, knownFolder: { _, path in path },
            session: { _, _ in .null }, runnableProject: { _, path in path },
            rpc: { _ in .init(caller: .nativeApp, ownerID: "devices-fixture") },
            authorize: { _, _, _, _, _, owner in await spy.asked(owner) },
            record: { _, _, _, _ in })
        let account = MACHINESMCP.AccountHalf(signedIn: signedIn, devices: signedIn ? [
            .init(name: "MacBook Pro", kind: .mac, isThisMac: true, addedAtMs: Int64(Self.now - 30 * 86_400_000), lastSeenAtMs: Int64(Self.now)),
            .init(name: "Mac mini", kind: .mac, isThisMac: false, addedAtMs: Int64(Self.now - 20 * 86_400_000), lastSeenAtMs: Int64(Self.now - 120_000), deviceId: "mini-id"),
            .init(name: "iPhone", kind: .phone, isThisMac: false, addedAtMs: Int64(Self.now - 2 * 86_400_000), lastSeenAtMs: Int64(Self.now - 600_000), deviceId: "phone-id"),
        ] + (twins ? [.init(name: "iPhone", kind: .phone, isThisMac: false, addedAtMs: nil, lastSeenAtMs: nil, deviceId: "phone-2")] : []) : [], reach: .init(available: signedIn, on: true, entitled: entitled))
        return try MACHINESMCP.deviceDefinitions(access: access, invoke: { channel, args, _ in
            await spy.note(channel, args)
            return answer(channel)
        }, account: { account }, signOut: { try await spy.signOut($0) }, rename: { await spy.rename($0, $1) })
    }

    func context(_ tool: String, attended: Bool = true) -> BackendMCPCallContext {
        .init(sessionID: "devices-fixture", machineID: "", projectRoot: nil, attended: attended,
              allowedTools: [tool], allowedTiers: [.read, .act, .alter], cancellation: .init())
    }

    func reply(_ value: BackendMCPToolReply) throws -> V {
        try V.parseJSON(Data((value.content.first?["text"].string ?? "null").utf8))
    }

    func testTheToolsAndWhatTheySayNeverNameTheOldWay() async throws {
        let tools = try tools(Spy())
        XCTAssertEqual(tools.map(\.spec.wireName), ["devices_page", "devices_remove", "devices_rename", "devices_sign_out"])
        for tool in tools {
            for text in [tool.spec.description, tool.title, tool.index ?? ""] {
                XCTAssertFalse(DevicesPage.saysRetiredWord(text), text)
            }
        }
        // The other tools about who reaches this computer.
        let rows = try BackendDeckToolsMachinesCatalogue.rows()
        for id in ["remote.status", "remote.manage"] {
            let row = try XCTUnwrap(rows.first { $0["id"].string == id })
            for key in ["title", "description", "index"] { XCTAssertFalse(DevicesPage.saysRetiredWord(row[key].string ?? ""), "\(id) \(key)") }
            let verbs = row["inputSchema"]["properties"]["do"]["enum"].elements?.compactMap(\.string) ?? []
            XCTAssertTrue(Set(verbs).isDisjoint(with: ["show-code", "cancel-code", "approve", "open-web", "pair"]), id)
        }
        let manage = try XCTUnwrap(rows.first { $0["id"].string == "machines.manage" })
        XCTAssertTrue(Set(manage["inputSchema"]["properties"]["do"]["enum"].elements?.compactMap(\.string) ?? []).isDisjoint(with: ["pair", "show-code", "cancel-code"]))
        for row in rows where row["module"].string == "machine-tools" {
            for key in ["title", "description", "index"] {
                XCTAssertNil((row[key].string ?? "").range(of: #"\b(pair|paired|pairing)\b"#, options: [.regularExpression, .caseInsensitive]), "\(row["id"].string ?? "") \(key)")
            }
        }
        let reach = try XCTUnwrap(BackendReachAccountTools.definitions().first)
        XCTAssertFalse(DevicesPage.saysRetiredWord(reach.description), reach.description)
    }

    func testThePageToolAnswersTheWindowsRowsAndOnlyReads() async throws {
        let spy = Spy(), page = try XCTUnwrap(try tools(spy).first)
        let result = try await page.handler(context("devices.page"), .object([]))
        XCTAssertFalse(result.isError)
        let value = try reply(result)
        let rows = value["devices"].elements ?? []
        XCTAssertEqual(rows.map { $0["name"].string ?? "" }, ["MacBook Pro", "Mac mini", "iPhone", "Chrome on Mac", "iPhone", "Android emulator"])
        XCTAssertEqual(rows.map { $0["joined"].string ?? "" }, ["account", "account", "account", "before accounts", "before accounts", "before accounts"])
        XCTAssertEqual(rows[0]["seen"].string, "This Mac")
        XCTAssertEqual(rows[3]["seen"].string, "Connected now")
        XCTAssertEqual(rows[5]["notSeenRecently"].bool, true)
        XCTAssertEqual(value["setting"]["title"].string, "Let my signed-in devices open this Mac")
        let text = String(decoding: try value.encodedJSON(), as: UTF8.self)
        XCTAssertFalse(DevicesPage.saysRetiredWord(text), text)
        XCTAssertFalse(text.contains("AB:CD"), "no fingerprints")
        // Opening the page reads; it never writes a record of the old way.
        let names = await spy.names
        XCTAssertEqual(Set(names), ["remote:status", "remote:devices", "machines:list"])
        let owners = await spy.owners
        XCTAssertEqual(owners, [false])

        let signedOut = try XCTUnwrap(try tools(Spy(), signedIn: false).first)
        let out = try reply(try await signedOut.handler(context("devices.page"), .object([])))
        XCTAssertEqual(out["note"].string, DevicesPage.signedOutLine)
        XCTAssertTrue(out["setting"].isNullish)
        let notOn = try XCTUnwrap(try tools(Spy(), entitled: false).first)
        let notOnReply = try await notOn.handler(context("devices.page"), .object([]))
        // A2: the switch's own line says it starts once the account has it; nothing claims devices can get in.
        XCTAssertEqual(try reply(notOnReply)["setting"]["state"].string, DevicesPage.notEntitledDetail)
        XCTAssertFalse(DevicesPage.notEntitledDetail.contains("can open this Mac"))
    }

    func testRemoveDoesWhatTheOldRemoveDid() async throws {
        let spy = Spy(), remove = try XCTUnwrap(try tools(spy)[1])
        let one = try await remove.handler(context("devices.remove"), .object([.init("ref", .string("device:p1"))]))
        XCTAssertFalse(one.isError)
        var calls = await spy.channels
        XCTAssertEqual(calls.filter { $0.0 == "remote:device:revoke" }.map(\.1), [[.string("p1")]])
        let owners = await spy.owners
        XCTAssertEqual(owners, [true], "removing asks the owner as remote.manage's revoke did")

        let quietSpy = Spy(), quiet = try XCTUnwrap(try tools(quietSpy)[1])
        let quietReply = try await quiet.handler(context("devices.remove"), .object([.init("notSeenRecently", .bool(true))]))
        XCTAssertFalse(quietReply.isError)
        calls = await quietSpy.channels
        XCTAssertEqual(calls.filter { $0.0 == "remote:device:revoke" }.map(\.1), [[.string("e1")]])

        let strangerSpy = Spy(), stranger = try XCTUnwrap(try tools(strangerSpy)[1])
        let refused = try await stranger.handler(context("devices.remove"), .object([.init("ref", .string("device:someone-else"))]))
        XCTAssertTrue(refused.isError)
        calls = await strangerSpy.channels
        XCTAssertFalse(calls.contains { $0.0 == "remote:device:revoke" })
        let ungranted = try await stranger.handler(context("devices.page"), .object([.init("ref", .string("device:p1"))]))
        XCTAssertTrue(ungranted.isError, "a caller not granted devices_remove cannot use it")
    }

    /// Owner, 14 Nov: devices_remove on an account device does what the page's row does: it signs that device out,
    /// with the same approval as every removal; never this Mac; a device holding the saved-passwords key is refused.
    func testRemoveSignsAnAccountDeviceOut() async throws {
        let spy = Spy(), tools = try tools(spy), page = try XCTUnwrap(tools.first), remove = try XCTUnwrap(tools[1] as BackendDeckToolsDefinition?)
        let rows = try reply(try await page.handler(context("devices.page"), .object([])))["devices"].elements ?? []
        XCTAssertTrue(rows[0]["ref"].isNullish, "this Mac has no ref: it cannot be signed out here")
        let phoneRef = try XCTUnwrap(rows.first { $0["name"].string == "iPhone" && $0["joined"].string == "account" }?["ref"].string)
        XCTAssertEqual(phoneRef, "account:phone-id")
        let done = try await remove.handler(context("devices.remove"), .object([.init("ref", .string(phoneRef))]))
        XCTAssertFalse(done.isError)
        let signedOut = await spy.signedOut
        XCTAssertEqual(signedOut, ["phone-id"], "only the chosen device")
        let owners = await spy.owners
        XCTAssertEqual(owners, [false, true], "the person approves the sign-out as every removal")
        let names = await spy.names
        XCTAssertFalse(names.contains("remote:device:revoke"))

        let refusedSpy = Spy(), refused = try XCTUnwrap(try self.tools(refusedSpy)[1])
        await refusedSpy.refuse(.holdsSavedPasswordsKey)
        let kept = try await refused.handler(context("devices.remove"), .object([.init("ref", .string("account:mini-id"))]))
        XCTAssertTrue(kept.isError)
        let keptSignedOut = await refusedSpy.signedOut
        XCTAssertEqual(keptSignedOut, [])
        // DEVICE-SIGNOUT-2: a browser whose reach removal did not reach the Cloud is an error, never "signed out".
        await refusedSpy.refuse(.notSignedIn)
        let notDone = try await refused.handler(context("devices.remove"), .object([.init("ref", .string("account:phone-id"))]))
        XCTAssertTrue(notDone.isError)
        let unknown = try await refused.handler(context("devices.remove"), .object([.init("ref", .string("account:someone-else"))]))
        XCTAssertTrue(unknown.isError)
    }

    /// Lost-device design B6: devices_sign_out signs one of his devices out by its name, a Mac that keeps the
    /// saved-passwords key included (the new Cloud takes it), with the person's approval as every removal. Refused
    /// (nothing changed, nobody asked) for any caller but Hoot, for a turn nobody attends, for this Mac, for an
    /// unknown name and for a name two devices share. devices_remove's account branch follows the same rule.
    func testSignOutByNameIsHootsAloneAndRefusesWhatItShould() async throws {
        let spy = Spy()
        let tool = try XCTUnwrap(try tools(spy).first { $0.spec.wireName == "devices_sign_out" })
        XCTAssertEqual(tool.spec.tier, .alter)
        let done = try await tool.handler(context("devices.sign_out"), .object([.init("device", .string("  mac MINI "))]))
        XCTAssertFalse(done.isError)
        XCTAssertEqual(try reply(done)["signedOut"].string, "Mac mini")
        let signedOut = await spy.signedOut
        XCTAssertEqual(signedOut, ["mini-id"], "a Mac that keeps the key is signed out like any device")
        let owners = await spy.owners
        XCTAssertEqual(owners, [true], "the person approves it as every removal")

        func refused(_ caller: BackendDeckToolsAppCaller.Kind = .local, attended: Bool = true, twins: Bool = false,
                     _ name: String, _ line: String, file: StaticString = #filePath, line number: UInt = #line) async throws {
            let other = Spy()
            let t = try XCTUnwrap(try tools(other, caller: caller, twins: twins).first { $0.spec.wireName == "devices_sign_out" })
            let answer = try await t.handler(context("devices.sign_out", attended: attended), .object([.init("device", .string(name))]))
            XCTAssertTrue(answer.isError, file: file, line: number)
            XCTAssertTrue((answer.content.first?["text"].string ?? "").contains(line), answer.content.first?["text"].string ?? "", file: file, line: number)
            let none = await other.signedOut, asked = await other.owners
            XCTAssertEqual(none, [], "nothing changed", file: file, line: number)
            XCTAssertEqual(asked, [], "nobody asked", file: file, line: number)
        }
        try await refused(.session, "Mac mini", "Hoot")      // a coding session: refused at the door already
        try await refused(.key, "Mac mini", "Only Hoot can sign a device out")      // an AI app with an access key
        try await refused(attended: false, "Mac mini", "needs your own request")
        try await refused(.local, "MacBook Pro", "To sign out this Mac use Profile")
        try await refused(.local, "Kitchen iPad", "No device of yours is called")
        try await refused(twins: true, "iPhone", "More than one device is called")

        // The other door that signs an account device out keeps the same rule.
        let remove = try XCTUnwrap(try tools(Spy(), caller: .session).first { $0.spec.wireName == "devices_remove" })
        let viaRemove = try await remove.handler(context("devices.remove"), .object([.init("ref", .string("account:mini-id"))]))
        XCTAssertTrue(viaRemove.isError)
    }

    /// A5: "not seen recently" with nobody matching: "nothing to remove", and the person is never asked.
    func testNothingNotSeenRecentlyAsksNobody() async throws {
        let spy = Spy()
        let remove = try XCTUnwrap(try tools(spy, answer: { channel in
            guard channel == "remote:devices" else { return DevicesPageToolsTests.answer(channel) }
            return .array([.object([.init("id", .string("p1")), .init("name", .string("iPhone")), .init("status", .string("approved")),
                                    .init("lastSeenAt", .number(DevicesPageToolsTests.now - 60_000))])])
        })[1])
        let result = try await remove.handler(context("devices.remove"), .object([.init("notSeenRecently", .bool(true))]))
        XCTAssertFalse(result.isError)
        let value = try reply(result)
        XCTAssertEqual(value["removed"].elements?.count, 0)
        XCTAssertEqual(value["message"].string, MACHINESMCP.nothingToRemove)
        let owners = await spy.owners
        XCTAssertEqual(owners, [], "nothing to remove: no approval asked")
        let names = await spy.names
        XCTAssertFalse(names.contains("remote:device:revoke"))
    }

    func testTheJoinSheetAndTheOtherMacsLineSayHowDevicesJoin() throws {
        XCTAssertFalse(DevicesPage.saysRetiredWord(DevicesPage.joinBySigningIn))
        XCTAssertFalse(DevicesPage.saysRetiredWord(NativeMacScreenSetting.refusal))
        XCTAssertFalse(DevicesPage.saysRetiredWord(BackendReachPairingLock.refusal))
        XCTAssertTrue(MACHINESDevicesScreen.signedIn(.signedIn) && MACHINESDevicesScreen.signedIn(.dormant) && !MACHINESDevicesScreen.signedIn(.signedOut))
        guard let dir = ProcessInfo.processInfo.environment["TD_DEVICES_WINDOW_FRAMES"] else { return }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let day = 86_400_000.0
        let account: [DevicesPage.AccountDevice] = [
            .init(name: "MacBook Pro", kind: .mac, isThisMac: true, addedAtMs: Int64(Self.now - 30 * day), lastSeenAtMs: Int64(Self.now), deviceId: "fixture-mac"),
            .init(name: "Mac mini", kind: .mac, isThisMac: false, addedAtMs: Int64(Self.now - 20 * day), lastSeenAtMs: Int64(Self.now - 120_000), deviceId: "fixture-mini"),
            .init(name: "Travel iPhone 17 Pro Max with a rather long name", kind: .phone, isThisMac: false, addedAtMs: Int64(Self.now - 2 * day),
                  lastSeenAtMs: Int64(Self.now - 600_000), deviceId: "fixture-phone")]
        let old: [DevicesPage.OldDevice] = [
            .init(ref: "device:p1", source: .device, name: "iPhone", lastSeenAtMs: Self.now - 17 * 60_000, connected: false),
            .init(ref: "device:b1", source: .device, name: "Chrome on Mac", lastSeenAtMs: Self.now - 3_600_000, connected: true),
            .init(ref: "machine:m1", source: .machine, name: "Office PC", lastSeenAtMs: nil, connected: false),
            .init(ref: "device:e1", source: .device, name: "Android emulator", lastSeenAtMs: Self.now - 20 * day, connected: false),
            .init(ref: "device:e2", source: .device, name: "iPhone Air", lastSeenAtMs: Self.now - 31 * day, connected: false)]
        let connections: [DevicesPage.Connection] = [
            .init(name: "Mac mini", atMs: Self.now - 120_000, opened: true),
            .init(name: "Travel iPhone 17 Pro Max with a rather long name", atMs: Self.now - 600_000, opened: true),
            .init(name: "Old tablet", atMs: Self.now - 2 * day, opened: false)]
        let states: [(String, DevicesPage)] = [
            ("both-groups", DevicesPage(signedIn: true, account: account,
                reach: .init(available: true, on: true, entitled: true, door: .ready, connections: connections), old: old, now: Self.now)),
            ("connecting", DevicesPage(signedIn: true, account: account,
                reach: .init(available: true, on: true, entitled: true, door: .connecting), old: [], now: Self.now)),
            ("not-reachable", DevicesPage(signedIn: true, account: account,
                reach: .init(available: true, on: true, entitled: true, door: .notReachable), old: [], now: Self.now)),
            ("signed-out", DevicesPage(signedIn: false, account: [], reach: .unknown, old: old, now: Self.now)),
            ("no-feature", DevicesPage(signedIn: true, account: account, reach: .init(available: true, on: true, entitled: false), old: [], now: Self.now)),
            ("empty", DevicesPage(signedIn: true, account: Array(account.prefix(1)),
                reach: .init(available: true, on: true, entitled: true, door: .ready), old: [], now: Self.now)),
        ]
        for (name, page) in states {
            for line in page.shownText { XCTAssertFalse(DevicesPage.saysRetiredWord(line), "\(name): \(line)") }
            for dark in [false, true] {
                try MACHINESHiddenRender.render(MACHINESDevicesScreen(fixture: true, fixturePage: page), dark: dark, size: CGSize(width: 760, height: 1100),
                    to: out.appendingPathComponent("MACHINES-devices-\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}

// review-fixes 2: device rename has its tool beside sign-out, same style and permissions.
extension DevicesPageToolsTests {
    func testRenameNamesADeviceAsTheNameRowDoes() async throws {
        let spy = Spy(), rename = try XCTUnwrap(try tools(spy)[2])
        XCTAssertEqual(rename.spec.wireName, "devices_rename")
        XCTAssertEqual(rename.spec.tier, .alter)
        let other = try await rename.handler(context("devices.rename"), .object([.init("ref", .string(DevicesPage.accountRef("mini-id"))), .init("name", .string("  Studio Mac  "))]))
        XCTAssertFalse(other.isError)
        XCTAssertEqual(try reply(other)["renamed"].string, "Studio Mac")
        let mine = try await rename.handler(context("devices.rename"), .object([.init("thisMac", .bool(true)), .init("name", .string("My MacBook"))]))
        XCTAssertTrue(mine.isError, "this Mac's row carries no deviceId in the fixture, so nothing is sent")
        let renamed = await spy.renamed
        XCTAssertEqual(renamed.map(\.0), ["mini-id"])
        XCTAssertEqual(renamed.map(\.1), ["Studio Mac"])
        let owners = await spy.owners
        XCTAssertEqual(owners, [true], "renaming asks as signing out does")
        // Nothing sent for a wrong ref, an empty name, or both handles at once.
        for args: NativeRPCValue in [.object([.init("ref", .string("account:nobody")), .init("name", .string("X"))]),
                                     .object([.init("ref", .string(DevicesPage.accountRef("mini-id"))), .init("name", .string("   "))]),
                                     .object([.init("ref", .string(DevicesPage.accountRef("mini-id"))), .init("thisMac", .bool(true)), .init("name", .string("X"))])] {
            let refused = try await rename.handler(context("devices.rename"), args)
            XCTAssertTrue(refused.isError)
        }
        let still = await spy.renamed
        XCTAssertEqual(still.count, 1)
        // Not granted: refused before anything is read.
        let denied = try await rename.handler(context("devices.page"), .object([.init("ref", .string(DevicesPage.accountRef("mini-id"))), .init("name", .string("Y"))]))
        XCTAssertTrue(denied.isError)
    }
}
