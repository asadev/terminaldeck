import Foundation
import Testing
@testable import TerminalDeckNativeCore

/// The Devices window without pairing (owner, 13 Nov): the account's devices, one switch, and the devices connected
/// before accounts folded by age. His own case from the screenshot of 13 Nov.
@Suite struct DevicesPageTests {
    static let now: Double = 1_794_000_000_000
    static let minute: Double = 60_000, day: Double = 86_400_000
    static let utc = TimeZone(identifier: "UTC")!, en = Locale(identifier: "en_GB")

    /// Two Macs and one phone signed in to the account.
    static let account = [
        DevicesPage.AccountDevice(name: "iPhone", kind: .phone, isThisMac: false, addedAtMs: Int64(now - 3 * day), lastSeenAtMs: Int64(now - 17 * minute)),
        DevicesPage.AccountDevice(name: "Mac mini", kind: .mac, isThisMac: false, addedAtMs: Int64(now - 20 * day), lastSeenAtMs: Int64(now - 2 * minute)),
        DevicesPage.AccountDevice(name: "MacBook Pro", kind: .mac, isThisMac: true, addedAtMs: Int64(now - 30 * day), lastSeenAtMs: Int64(now)),
    ]
    /// The eight entries of his screenshot, connected the old way; several not seen for 14 days or more.
    static let old: [DevicesPage.OldDevice] = [
        .init(ref: "device:a1", source: .device, name: "iPhone", lastSeenAtMs: now - 17 * minute, connected: false),
        .init(ref: "device:a2", source: .device, name: "TD Hoot Edition (Claude)", lastSeenAtMs: now - 2 * day, connected: false),
        .init(ref: "device:a3", source: .device, name: "Android emulator", lastSeenAtMs: now - 20 * day, connected: false),
        .init(ref: "device:a4", source: .device, name: "iPhone Air", lastSeenAtMs: now - 31 * day, connected: false),
        .init(ref: "device:a5", source: .device, name: "Chrome on Mac", lastSeenAtMs: now - 60 * minute, connected: true),
        .init(ref: "device:a6", source: .device, name: "Chrome on Mac", lastSeenAtMs: now - 14 * day, connected: false),
        .init(ref: "device:a7", source: .device, name: "Chrome on Mac", lastSeenAtMs: now - 45 * day, connected: false),
        .init(ref: "device:a8", source: .device, name: "Chrome on Mac", lastSeenAtMs: nil, connected: false),
    ]

    func page(signedIn: Bool = true, reach: DevicesPage.Reach = .init(available: true, on: true, entitled: true),
              old: [DevicesPage.OldDevice] = old) -> DevicesPage {
        DevicesPage(signedIn: signedIn, account: Self.account, reach: reach, old: old, now: Self.now, timeZone: Self.utc, locale: Self.en)
    }

    @Test("His case: this Mac first, then the phone and the other Mac with names and dates; old ones folded at 14 days")
    func hisCase() {
        let page = page()
        #expect(page.showsSetting && page.settingOn && page.featureNote == nil)
        #expect(page.accountRows.map(\.name) == ["MacBook Pro", "Mac mini", "iPhone"])
        #expect(page.accountRows[0].isThisMac && page.accountRows[0].seen == "This Mac")
        #expect(page.accountRows[1].detail.hasPrefix("Mac · Added ") && page.accountRows[1].seen.hasPrefix("Last seen "))
        #expect(page.accountRows[2].kind == .phone && page.accountRows[2].added?.hasPrefix("Added ") == true)
        #expect(page.accountRows.allSatisfy { $0.id.hasPrefix("account-") })
        // Connected now first, then newest; 14 days or more (and never seen) folded.
        #expect(page.oldRecent.map(\.ref) == ["device:a5", "device:a1", "device:a2"])
        #expect(page.oldRecent[0].seen == "Connected now")
        #expect(Set(page.oldQuiet.map(\.ref)) == ["device:a3", "device:a4", "device:a6", "device:a7", "device:a8"])
        #expect(DevicesPage.quietTitle(page.oldQuiet.count) == "Not seen recently (5)")
        #expect(page.shownText.contains(DevicesPage.oldTitle) && page.shownText.contains(DevicesPage.oldLine))
        #expect(page.shownText.contains("Not seen recently (5)") && page.shownText.contains(DevicesPage.removeAllTitle))
    }

    @Test("Signed out: one sentence, no account rows, no switch; the old ones are still listed")
    func signedOut() {
        let page = page(signedIn: false)
        #expect(!page.signedIn && page.accountRows.isEmpty && !page.showsSetting && page.featureNote == nil)
        #expect(page.shownText.contains(DevicesPage.signedOutLine))
        #expect(page.showsOld)
        #expect(page.wireValue["note"].string == DevicesPage.signedOutLine)
    }

    @Test("The account does not have the feature yet: the switch's line says it starts once the account has it, nothing claims devices get in")
    func notSwitchedOn() {
        let page = page(reach: .init(available: true, on: true, entitled: false, door: .ready))
        #expect(page.settingDetail == DevicesPage.notEntitledDetail && page.door == nil && page.featureNote == nil)
        #expect(!page.shownText.contains { $0.contains("can open this Mac") && $0 != DevicesPage.settingTitle })
        // Without a switch on screen (not assembled yet), the phones' sentence stands in.
        let noSwitch = self.page(reach: .init(available: false, on: true, entitled: false))
        #expect(noSwitch.featureNote == DevicesPage.notSwitchedOn)
        let unknown = self.page(reach: .unknown)
        #expect(unknown.featureNote == nil && !unknown.showsSetting)
        let off = self.page(reach: .init(available: true, on: false, entitled: true, door: .ready))
        #expect(!off.settingOn && off.settingDetail == DevicesPage.settingOffDetail && off.door == nil)
    }

    @Test("A1: the line under the switch is the door's real state; never ready unless running, listed and connected")
    func doorLine() {
        #expect(page(reach: .init(available: true, on: true, entitled: true, door: .ready)).settingDetail == "Ready: your signed-in devices can open this Mac.")
        #expect(page(reach: .init(available: true, on: true, entitled: true, door: .connecting)).settingDetail == "Connecting…")
        #expect(page(reach: .init(available: true, on: true, entitled: true, door: .notReachable)).settingDetail == "Not reachable right now, trying again.")
        // Not known yet reads as connecting, never as ready.
        #expect(page(reach: .init(available: true, on: true, entitled: true)).door == .connecting)
        #expect(page(reach: .init(available: true, on: true, entitled: nil, door: .ready)).door == .connecting)
        func door(running: Bool = true, startFailed: Bool = false, published: Bool = true, publishFailed: Bool = false,
                  relay: Bool? = true, for ms: Double = 0) -> DevicesPage.Door {
            DevicesPage.door(running: running, startFailed: startFailed, published: published, publishFailed: publishFailed,
                             relayConnected: relay, connectingForMs: ms)
        }
        #expect(door() == .ready && door(relay: nil) == .ready)
        #expect(door(running: false) == .connecting && door(published: false) == .connecting && door(relay: false) == .connecting)
        #expect(door(running: false, startFailed: true) == .notReachable && door(published: false, publishFailed: true) == .notReachable)
        #expect(door(running: false, for: 59_999) == .connecting && door(running: false, for: 60_000) == .notReachable)
        // The app starts remote access by itself only for a signed-in Mac whose switch is on and whose account has it.
        #expect(DevicesPage.startsDoor(on: true, signedIn: true, entitled: true, running: false))
        #expect(!DevicesPage.startsDoor(on: false, signedIn: true, entitled: true, running: false), "his OFF is never touched")
        #expect(!DevicesPage.startsDoor(on: true, signedIn: true, entitled: true, running: true))
        #expect(!DevicesPage.startsDoor(on: true, signedIn: true, entitled: true, running: nil))
        #expect(!DevicesPage.startsDoor(on: true, signedIn: false, entitled: true, running: false))
        #expect(!DevicesPage.startsDoor(on: true, signedIn: true, entitled: false, running: false))
        #expect(!DevicesPage.startsDoor(on: true, signedIn: true, entitled: nil, running: false))
    }

    @Test("A3 and A6: account rows carry Remove (not this Mac); last connections show names and dates, newest first")
    func removeAndLastConnections() {
        let account = Self.account.enumerated().map { i, d in
            DevicesPage.AccountDevice(name: d.name, kind: d.kind, isThisMac: d.isThisMac, addedAtMs: d.addedAtMs, lastSeenAtMs: d.lastSeenAtMs, deviceId: "d\(i)")
        }
        let connections = (0..<10).map { DevicesPage.Connection(name: "Phone \($0)", atMs: Self.now - Double($0) * Self.minute, opened: $0 != 1) }
        let page = DevicesPage(signedIn: true, account: account, reach: .init(available: true, on: true, entitled: true, door: .ready, connections: connections.reversed()),
                               old: Self.old, now: Self.now, timeZone: Self.utc, locale: Self.en)
        #expect(page.accountRows.map(\.canRemove) == [false, true, true])
        #expect(page.accountRows[0].ref == nil && page.accountRows[1].ref == "d1")
        #expect(page.lastConnections.count == 8)
        #expect(page.lastConnections[0].hasPrefix("Phone 0 opened this Mac · ") && page.lastConnections[1].hasPrefix("Phone 1 was turned away · "))
        #expect(page.shownText.contains(DevicesPage.lastConnectionsTitle) && page.shownText.contains(DevicesPage.detailsTitle))
        // Never the account's ids on screen or in the tool answer.
        #expect(!page.shownText.contains { $0.contains("d1") })
        let wire = String(decoding: (try? page.wireValue.encodedJSON()) ?? Data(), as: UTF8.self)
        #expect(!wire.contains("\"d1\""))
        // Signed out: no connections.
        #expect(DevicesPage(signedIn: false, account: [], reach: .init(available: true, on: true, entitled: true, connections: connections), old: []).lastConnections.isEmpty)
    }

    @Test("No old ones: no second group at all")
    func noOldGroup() {
        let page = page(old: [])
        #expect(!page.showsOld && !page.shownText.contains(DevicesPage.oldTitle))
        #expect(page.wireValue["devices"].elements?.count == 3)
    }

    @Test("No pairing word, code, QR or id in anything the page or its tool answer says")
    func noRetiredWords() throws {
        for page in [page(), page(signedIn: false), page(reach: .init(available: true, on: false, entitled: false)), page(old: []),
                     page(reach: .init(available: true, on: true, entitled: true, door: .notReachable,
                                       connections: [.init(name: "iPhone", atMs: Self.now, opened: true)]))] {
            for line in page.shownText { #expect(!DevicesPage.saysRetiredWord(line), "\(line)") }
            let wire = String(decoding: try page.wireValue.encodedJSON(), as: UTF8.self)
            #expect(!DevicesPage.saysRetiredWord(wire), "\(wire)")
        }
        for line in [DevicesPage.title, DevicesPage.subtitle, DevicesPage.signedOutLine, DevicesPage.settingTitle, DevicesPage.settingOnDetail,
                     DevicesPage.settingOffDetail, DevicesPage.notSwitchedOn, DevicesPage.noOtherDevice, DevicesPage.oldTitle, DevicesPage.oldLine,
                     DevicesPage.joinBySigningIn, DevicesPage.doorReady, DevicesPage.doorConnecting, DevicesPage.doorNotReachable,
                     DevicesPage.notEntitledDetail, DevicesPage.lastConnectionsTitle, DevicesPage.detailsTitle] {
            #expect(!DevicesPage.saysRetiredWord(line), "\(line)")
        }
        // The check itself catches the words it is for.
        for word in ["Pair a device", "Paired 1 month ago", "pairing", "Show the code", "Scan the QR"] { #expect(DevicesPage.saysRetiredWord(word)) }
        #expect(!DevicesPage.saysRetiredWord("Repaired the cable"))
    }

    @Test("The tool rows are the page's rows: account devices first, then the old ones marked as such")
    func toolRows() {
        let rows = page().wireValue["devices"].elements ?? []
        #expect(rows.count == 3 + 8)
        #expect(rows.prefix(3).allSatisfy { $0["joined"].string == "account" && $0["ref"].isNullish })
        #expect(rows.dropFirst(3).allSatisfy { $0["joined"].string == "before accounts" && $0["ref"].string?.hasPrefix("device:") == true })
        #expect(rows.dropFirst(3).filter { $0["notSeenRecently"].bool == true }.count == 5)
        #expect(rows[0]["thisMac"].bool == true && rows[0]["name"].string == "MacBook Pro")
    }

    @Test("Old devices: approved ones only, plus the computers this Mac reaches; a computer offline says Not connected")
    func oldDevices() {
        let devices = [RemoteDevice(id: "p1", name: "iPhone", state: .approved, lastSeenAt: Self.now - Self.minute),
                       RemoteDevice(id: "p2", name: "Waiting phone", state: .pending),
                       RemoteDevice(id: "p3", name: "Gone phone", state: .revoked)]
        let old = DevicesPage.oldDevices(devices: devices, connected: ["p1"], machines: [PairedMachine(id: "m1", name: "Office PC")], online: [])
        #expect(old.map(\.ref) == ["device:p1", "machine:m1"])
        let page = DevicesPage(signedIn: true, account: [], reach: .unknown, old: old, now: Self.now)
        #expect(page.oldRecent.map(\.seen) == ["Connected now"] && page.oldQuiet.map(\.seen) == ["Not connected"])
    }

    @Test("From the account snapshot: one row per active device, this Mac marked, replaced and removed entries left out")
    func fromSnapshot() {
        let key = CloudPublicJWK(kty: "EC", crv: "P-256", x: "x", y: "y")
        func device(_ id: String, _ label: String, _ platform: CloudPlatform, status: CloudDeviceStatus = .active, replaced: String? = nil) -> CloudDevice {
            var made = CloudDevice(deviceId: id, label: label, platform: platform, appVersion: "fixture", status: status, secretsApproved: false,
                                   lastSeenAt: Int64(Self.now - Self.minute), signPublicJwk: key, wrapPublicJwk: key, registeredAt: Int64(Self.now - Self.day))
            made.displayName = label + " (friendly)"
            made.supersededBy = replaced
            return made
        }
        let snapshot = CloudAccountSnapshot(phase: .signedIn, gate: .closed, devices: [
            device("d-book", "MacBook", .macos), device("d-mini", "Mac mini", .macos), device("d-phone", "iPhone", .ios),
            device("d-web", "Chrome", .web), device("d-pc", "Office", .windows), device("d-old", "MacBook", .macos, replaced: "d-book"),
            device("d-gone", "Lost phone", .android, status: .revoked)],
            trust: [CloudDeviceTrustRow(deviceId: "d-book", name: "MacBook", standing: .thisMac, code: nil, keyId: nil, signKey: nil)])
        let rows = DevicesPage.accountDevices(snapshot)
        #expect(rows.map(\.name) == ["MacBook (friendly)", "Mac mini (friendly)", "iPhone (friendly)", "Chrome (friendly)", "Office (friendly)"])
        #expect(rows.map(\.kind) == [.mac, .mac, .phone, .browser, .pc])
        #expect(rows.filter(\.isThisMac).map(\.name) == ["MacBook (friendly)"])
    }
}
