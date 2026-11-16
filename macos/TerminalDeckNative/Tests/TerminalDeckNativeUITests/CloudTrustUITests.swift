import AppKit
import CryptoKit
import SwiftUI
import Testing
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

/// Lean scope item 4, the window side: the trust sheet, the new-Mac sheet and the Devices rows. No window, no
/// Keychain and no network are used; the sheets are built and inspected, never shown.
@Suite("Cloud device trust — the sheets in this Mac's window")
@MainActor
struct CloudTrustUITests {
    static let idA = "10000000-0000-4000-8000-00000000000a"
    static let idB = "10000000-0000-4000-8000-00000000000b"
    static let idC = "10000000-0000-4000-8000-00000000000c"

    private func jwk() -> CloudPublicJWK {
        let point = P256.Signing.PrivateKey().publicKey.x963Representation
        return .init(kty: "EC", crv: "P-256", x: BackendCloudAccountIdentity.base64(Data(point[1..<33])), y: BackendCloudAccountIdentity.base64(Data(point[33..<65])))
    }
    private func device(_ id: String, _ name: String, _ key: CloudPublicJWK, added: Int64? = nil) -> CloudDevice {
        .init(deviceId: id, label: name, platform: .macos, appVersion: "fixture", status: .active, secretsApproved: false,
              lastSeenAt: 0, signPublicJwk: key, wrapPublicJwk: key, registeredAt: added)
    }
    private func row(_ id: String, _ name: String, _ key: CloudPublicJWK, waiting: Int = 0) throws -> CloudDeviceTrustRow {
        try #require(BackendCloudTrustRows.build(devices: [device(id, name, key, added: 1_794_000_000_000)], list: nil, thisDeviceId: nil,
                                                 waiting: [id: waiting]).first)
    }

    @Test func notNowIsTheDefaultButtonAndTrustTakesAClick() throws {
        let shown = try row(Self.idA, "MacBook Air", jwk(), waiting: 3)
        let capture = try #require(BackendCloudTrustCapture(row: shown))
        let alert = NativeCloudTrustSheets.trustAlert(capture, waiting: shown.waiting)
        #expect(alert.buttons.count == 2)
        #expect(alert.buttons[0].title == "Not now")
        #expect(alert.buttons[0].keyEquivalent == "\r")
        #expect(alert.buttons[1].title == "Trust this device")
        #expect(alert.buttons[1].keyEquivalent == "")
        #expect(NativeCloudTrustSheets.trustAccept == .alertSecondButtonReturn)
        // The title carries nothing the device chose; the name is a quoted claim in the text; the code of the very
        // key a press would store stands alone below, in its own large fixed-width line.
        #expect(alert.messageText == "Trust this device?")
        #expect(alert.informativeText.contains("It calls itself: “MacBook Air”"))
        #expect(!alert.informativeText.contains(capture.code))
        let codeField = try #require(alert.accessoryView as? NSTextField)
        #expect(codeField.stringValue == capture.code)
        #expect(alert.informativeText.contains("3 changes waiting"))
        let code = try #require(BackendCloudDeviceCode.code(deviceId: capture.deviceId, key: capture.signKey))
        #expect(code.code == capture.code)
        #expect(code.keyId == capture.keyId)
    }
    @Test func aDeviceNameCannotFakeACodeOnTheRowTheNewMacSheetOrTheTrustSheet_M1() throws {
        // Security review M1: the intruder names its device "MacBook Air" plus a second line showing the REAL Mac's code.
        let fake = "MacBook Air\nCode: 4F2A 91C3 B07E 55D1 8A2C"
        let plain = BackendCloudTrustRows.plainName(fake)
        #expect(plain == "MacBook Air Code")
        #expect(!plain.contains("\n"))
        #expect(!plain.contains(":"))
        #expect(!plain.contains("4F2A"))
        // A code written without spaces, a right-to-left override, invisible characters and a long name.
        #expect(BackendCloudTrustRows.plainName("Air 4F2A91C3B07E55D18A2C") == "Air")
        let turned = BackendCloudTrustRows.plainName("Mac\u{202E}koob\u{200B} Air\u{0007}")
        let turnedScalars: [UInt32] = turned.unicodeScalars.map { $0.value }
        let hasOverride = turnedScalars.contains(UInt32(0x202E))
        let hasInvisible = turnedScalars.contains(UInt32(0x200B))
        let hasControl = turnedScalars.contains(UInt32(0x07))
        #expect(!hasOverride)
        #expect(!hasInvisible)
        #expect(!hasControl)
        let long = BackendCloudTrustRows.plainName(String(repeating: "m", count: 80))
        #expect(long.count == 41)
        #expect(long.hasSuffix("…"))
        #expect(BackendCloudTrustRows.plainName("\n\t \u{202E}") == "Unnamed device")
        #expect(BackendCloudTrustRows.plainName("Asad's MacBook Pro 2024") == "Asad's MacBook Pro 2024")
        // The row (the Devices list and the new-Mac sheet draw the same row) carries only the plain form.
        let key = jwk()
        let built = BackendCloudTrustRows.build(devices: [device(Self.idA, fake, key)], list: nil, thisDeviceId: nil)
        let row = try #require(built.first)
        #expect(row.name == plain)
        #expect(NativeCloudTrustWords.claim(row) == "Calls itself: “MacBook Air Code”")
        let state = NativeCloudSetupSheetState(rows: [row], use: { _ in }, cancel: {})
        #expect(state.rows.first?.name == plain)
        // The trust sheet: nothing of the name in the title, no code in the text, the true code alone below.
        let capture = try #require(BackendCloudTrustCapture(row: row))
        let alert = NativeCloudTrustSheets.trustAlert(capture, waiting: 0)
        #expect(alert.messageText == "Trust this device?")
        #expect(!alert.informativeText.contains("4F2A"))
        #expect(!alert.informativeText.contains(capture.code))
        let shown = try #require(alert.accessoryView as? NSTextField)
        #expect(shown.stringValue == capture.code)
        // Even a capture made by hand with the raw name is filtered where it is shown.
        let raw = BackendCloudTrustCapture(deviceId: capture.deviceId, name: fake, signKey: capture.signKey, keyId: capture.keyId, code: capture.code)
        let rawAlert = NativeCloudTrustSheets.trustAlert(raw, waiting: 0)
        #expect(!rawAlert.informativeText.contains("4F2A"))
        #expect(rawAlert.informativeText.contains("“MacBook Air Code”"))
        // The status line quotes the claim.
        let waiting = BackendCloudTrustRows.build(devices: [device(Self.idA, fake, key)], list: nil, thisDeviceId: nil, waiting: [Self.idA: 2])
        let status = NativeCloudTrustWords.status(CloudAccountSnapshot(phase: .signedIn, gate: CloudGate(features: ["cloud"], storageEntitled: true), trust: waiting, heldChanges: 2))
        #expect(status == "Changes from “MacBook Air Code” are waiting for you to trust it")
    }
    @Test func aSheetClosesWhenTheDeviceListChanges_R1() throws {
        let first = jwk()
        let rows = try [row(Self.idA, "MacBook Air", first), row(Self.idB, "Mac Studio", jwk())]
        let drawn = NativeCloudTrustSheets.fingerprint(rows)
        // No sheet open: nothing to close. The same list: stays open.
        #expect(!NativeCloudTrustSheets.mustClose(drawn: nil, now: rows))
        #expect(!NativeCloudTrustSheets.mustClose(drawn: drawn, now: rows))
        // Only a waiting count moved: the list of devices and keys is the same.
        let counted = try [row(Self.idA, "MacBook Air", first, waiting: 9), rows[1]]
        #expect(!NativeCloudTrustSheets.mustClose(drawn: drawn, now: counted))
        // Another key for a device, a device added, a device gone: the sheet closes.
        let rekeyed = try [row(Self.idA, "MacBook Air", jwk()), rows[1]]
        #expect(NativeCloudTrustSheets.mustClose(drawn: drawn, now: rekeyed))
        let grown = try rows + [row(Self.idC, "iMac", jwk())]
        #expect(NativeCloudTrustSheets.mustClose(drawn: drawn, now: grown))
        #expect(NativeCloudTrustSheets.mustClose(drawn: drawn, now: [rows[0]]))
    }
    @Test func nothingIsTickedOnTheNewMacSheetAndOnlyReadableDevicesCanBe() throws {
        let good = try row(Self.idA, "Mac Studio", jwk())
        // Two devices that show ONE code (run 14): the alarm arrives on the second only, and NEITHER can be ticked.
        let firstId = "10000000-0000-4000-8000-00000000000e"
        let first = try row(firstId, "Mac Studio", jwk())
        let twinKey = jwk()
        let twin = CloudDeviceTrustRow(deviceId: Self.idB, name: "Mac Studio", standing: .new, code: first.code, keyId: BackendCloudDeviceCode.keyId(twinKey),
                                       signKey: twinKey, sameCode: true)
        let unreadable = CloudDeviceTrustRow(deviceId: Self.idC, name: "iMac", standing: .new, code: nil, keyId: nil, signKey: nil)
        let used = Used()
        let state = NativeCloudSetupSheetState(rows: [good, first, twin, unreadable], pressRefused: { false }, use: { used.values.append($0) }, cancel: {})
        #expect(state.ticked.isEmpty)
        #expect(state.captures.isEmpty)
        #expect(first.canBeTrusted)
        let blocked = state.rows.filter({ $0.sameCode && !$0.canBeTrusted }).map({ $0.deviceId })
        #expect(blocked == [firstId, Self.idB])
        // The trust sheet judges the same way: the first of the two cannot be captured among the others.
        let judged = NativeCloudTrustSheets.judged(first, among: [good, first, twin])
        #expect(NativeCloudTrustWords.alarm(judged) == NativeCloudTrustWords.sameCode)
        #expect(BackendCloudTrustCapture(row: judged) == nil)
        state.tick(firstId, true)
        state.tick(Self.idB, true)
        state.tick(Self.idC, true)
        state.tick("10000000-0000-4000-8000-0000000000ff", true)
        #expect(state.ticked.isEmpty)
        state.tick(Self.idA, true)
        #expect(state.ticked == [Self.idA])
        let expected = try #require(BackendCloudTrustCapture(row: good))
        #expect(state.captures == [expected])
        state.use(state.captures)
        #expect(used.values == [[expected]])
        state.tick(Self.idA, false)
        #expect(state.captures.isEmpty)
    }
    @Test func aTickThatFollowsRemoteInputIsNotTaken_S3() throws {
        // Security review S3: the phone could tick a device and leave the person to press "Use the ticked devices".
        let good = try row(Self.idA, "Mac Studio", jwk())
        let remote = Flag()
        let state = NativeCloudSetupSheetState(rows: [good], pressRefused: { remote.on }, use: { _ in }, cancel: {})
        remote.on = true
        state.tick(Self.idA, true)
        #expect(state.ticked.isEmpty)
        #expect(state.captures.isEmpty)
        // The person's own tick is taken.
        remote.on = false
        state.tick(Self.idA, true)
        #expect(state.ticked == [Self.idA])
        // Unticking is always taken: it can only take a device off the press.
        remote.on = true
        state.tick(Self.idA, false)
        #expect(state.ticked.isEmpty)
    }
    @Test func aRemovedDeviceAndALookAlikeCodeAreSaidInPlainWords_S5() throws {
        let key = jwk()
        let removed = CloudDeviceTrustRow(deviceId: Self.idA, name: "Old iMac", standing: .new, code: "4F2A 91C3 B07E 55D1 8A2C", keyId: nil, signKey: key, removed: true)
        #expect(NativeCloudTrustWords.standing(removed) == "Removed (reported)")
        #expect(NativeCloudTrustWords.alarm(removed) == NativeCloudTrustWords.removed)
        #expect(!removed.canBeTrusted)
        let state = NativeCloudSetupSheetState(rows: [removed], lookAlike: [Self.idA], pressRefused: { false }, use: { _ in }, cancel: {})
        state.tick(Self.idA, true)
        #expect(state.ticked.isEmpty)
        #expect(state.lookAlike == [Self.idA])
        #expect(NativeCloudTrustWords.lookAlike == "This code looks like another one here. Compare every character.")
        // The trust sheet for one device says it too, and only then.
        let live = try row(Self.idB, "MacBook Air", jwk())
        let capture = try #require(BackendCloudTrustCapture(row: live))
        let warned = NativeCloudTrustSheets.trustAlert(capture, waiting: 0, lookAlike: true)
        #expect(warned.informativeText.contains(NativeCloudTrustWords.lookAlike))
        let quiet = NativeCloudTrustSheets.trustAlert(capture, waiting: 0)
        #expect(!quiet.informativeText.contains(NativeCloudTrustWords.lookAlike))
    }
    @MainActor private final class Flag { var on = false }
    @Test func theWordsSayHowThisMacKnowsADevice() throws {
        let key = jwk()
        let new = try row(Self.idA, "MacBook Air", key, waiting: 1)
        #expect(NativeCloudTrustWords.standing(new) == "New device")
        let detail = try #require(NativeCloudTrustWords.detail(new))
        #expect(detail.contains("(reported)"))
        #expect(detail.contains("1 change waiting"))
        let known = CloudDeviceTrustRow(deviceId: Self.idA, name: "MacBook Air", standing: .trusted, code: new.code, keyId: new.keyId, signKey: key, knownSince: 1_794_000_000_000)
        #expect(NativeCloudTrustWords.standing(known).hasPrefix("Known to this Mac since "))
        #expect(NativeCloudTrustWords.detail(known) == nil)
        let mine = CloudDeviceTrustRow(deviceId: Self.idA, name: "This Mac", standing: .thisMac, code: new.code, keyId: new.keyId, signKey: key)
        #expect(NativeCloudTrustWords.standing(mine) == "This Mac")
    }
    @Test func thisMacsMemoryWaitsForTheNewMacSheetToBeAnswered_handBack4() async {
        // From the start of a sign-in until the person answers the new-Mac sheet, this Mac's own memory is not set up.
        let model = NativeCloudAccount()
        #expect(!model.newMacPending) // a Mac that was already signed in at launch has nothing to answer
        model.fixtureBeginNewMac()
        #expect(model.newMacPending)
        // "Use the ticked devices" counts only when the trust was really stored (here there is nothing to store).
        await model.useTicked([])
        #expect(model.newMacPending)
        let stored = await model.trust([], restore: true)
        #expect(!stored)
        // "Not now" is an answer.
        model.answerNewMac()
        #expect(!model.newMacPending)
        // Answering twice changes nothing.
        model.answerNewMac()
        #expect(!model.newMacPending)
    }
    @Test func theFirstSaveSaysHowFarItIsAndWhenItContinues() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Dubai"))
        let noon = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 12)))
        func at(hours: Double) -> Int64 { Int64((noon.timeIntervalSince1970 + hours * 3600) * 1000) }
        let running = CloudBaselineProgress(total: 5_000, sent: 1_200, filesWaiting: 0, waitingUntil: nil, reason: nil)
        #expect(NativeCloudTrustWords.baseline(running, now: noon, calendar: calendar) == "1,200 of 5,000 changes saved")
        // 14 Nov: no daily allowance; a wait is short and is said as the time it goes on, never "tomorrow".
        let paused = CloudBaselineProgress(total: 5_000, sent: 1_200, filesWaiting: 2, waitingUntil: at(hours: 0.1), reason: "Cloud asked this Mac to slow down for a moment.")
        let pausedLine = NativeCloudTrustWords.baseline(paused, now: noon, calendar: calendar)
        #expect(pausedLine.hasPrefix("1,200 of 5,000 changes saved, 2 files still to send; continues by itself at "))
        #expect(pausedLine.contains("12:06"))
        #expect(pausedLine.hasSuffix(". Cloud asked this Mac to slow down for a moment."))
        #expect(!pausedLine.contains("tomorrow") && !pausedLine.contains("today") && !pausedLine.contains("allowance"))
        let over = CloudBaselineProgress(total: 10, sent: 9, filesWaiting: 1, waitingUntil: at(hours: -0.1), reason: nil)
        #expect(NativeCloudTrustWords.baseline(over, now: noon, calendar: calendar) == "9 of 10 changes saved, 1 file still to send; continues in a moment")
    }
    @Test func theStatusNeverReadsConnectedWhileChangesWait() throws {
        let gate = CloudGate(features: ["cloud"], storageEntitled: true)
        let key = jwk()
        let waiting = try row(Self.idA, "MacBook Air", key, waiting: 14)
        let quiet = try row(Self.idB, "Mac Studio", jwk())
        let one = CloudAccountSnapshot(phase: .signedIn, gate: gate, trust: [waiting, quiet], heldChanges: 14)
        #expect(NativeCloudTrustWords.status(one) == "Changes from “MacBook Air” are waiting for you to trust it")
        let other = try row(Self.idC, "iMac", jwk(), waiting: 2)
        let two = CloudAccountSnapshot(phase: .signedIn, gate: gate, trust: [waiting, other], heldChanges: 16)
        #expect(NativeCloudTrustWords.status(two) == "Changes from 2 devices are waiting for you to trust them")
        // Waiting changes whose device the service does not list are still said.
        let unlisted = CloudAccountSnapshot(phase: .signedIn, gate: gate, trust: [quiet], heldChanges: 3)
        #expect(NativeCloudTrustWords.status(unlisted) != "Connected")
        #expect(NativeCloudTrustWords.status(CloudAccountSnapshot(phase: .signedIn, gate: gate, trust: [quiet])) == "Connected")
        #expect(NativeCloudTrustWords.status(CloudAccountSnapshot(phase: .paused, gate: gate, trust: [waiting], heldChanges: 14)) == "Paused")
    }
    @Test func theDevicesRowsAndTheNewMacSheetRenderInBothThemes() throws {
        let mine = jwk()
        let own = CloudDeviceTrustRow(deviceId: Self.idC, name: "Fixture Mac mini", standing: .thisMac,
                                      code: BackendCloudDeviceCode.code(deviceId: Self.idC, key: mine)?.code, keyId: BackendCloudDeviceCode.keyId(mine), signKey: mine)
        let known = CloudDeviceTrustRow(deviceId: Self.idB, name: "Fixture Mac Studio", standing: .trusted, code: "4F2A 91C3 B07E 55D1 8A2C", keyId: nil, signKey: nil,
                                        knownSince: 1_794_000_000_000)
        let new = try row(Self.idA, "Fixture MacBook Air", jwk(), waiting: 14)
        // Two devices, two keys, ONE code. The alarm is handed over on the second only (run 14's pictures showed the
        // first with an enabled Trust button and an enabled tick box): both are drawn warned and neither can be trusted.
        let twinKey = jwk()
        let twin = CloudDeviceTrustRow(deviceId: "10000000-0000-4000-8000-00000000000d", name: "Fixture MacBook Air", standing: .new, code: new.code,
                                       keyId: BackendCloudDeviceCode.keyId(twinKey), signKey: twinKey, sameCode: true)
        // Rendered proof goes under the agreed scratch root whatever launched the tests.
        let approved = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Deck Dev/notes/cloud-test-20261112").resolvingSymlinksInPath()
        let root = approved.appendingPathComponent("a-trust-render-" + UUID().uuidString + "/proof")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = NativeCloudSetupSheetState(rows: [new, twin], among: [own, known, new, twin], use: { _ in }, cancel: {})
        #expect(state.rows.count == 2)
        #expect(state.rows.allSatisfy({ $0.sameCode && !$0.canBeTrusted }))
        // The Devices rows as the Cloud page draws them: the list judged as a whole.
        let devices = BackendCloudTrustRows.alarmed([own, known, new, twin])
        let warned = devices.filter({ NativeCloudTrustWords.alarm($0) == NativeCloudTrustWords.sameCode }).map({ $0.deviceId })
        #expect(warned == [Self.idA, "10000000-0000-4000-8000-00000000000d"])
        #expect(devices.filter({ $0.canBeTrusted }).isEmpty)
        for dark in [false, true] {
            let page = Form { Section("Devices") { ForEach(devices) { NativeCloudDevicePlainRow(row: $0, lastSeen: nil, askMode: true) {} } } }
                .formStyle(.grouped).environment(\.colorScheme, dark ? .dark : .light).frame(width: 760, height: 420)
            try render(AnyView(page), size: NSSize(width: 760, height: 420), dark: dark, to: root.appendingPathComponent("cloud-devices-\(dark ? "dark" : "light").png"))
            let sheet = NativeCloudSetupSheet(state: state).environment(\.colorScheme, dark ? .dark : .light)
            try render(AnyView(sheet), size: NSSize(width: 608, height: 520), dark: dark, to: root.appendingPathComponent("cloud-new-mac-\(dark ? "dark" : "light").png"))
        }
    }
    @MainActor private final class Used { var values: [[BackendCloudTrustCapture]] = [] }
    private func render(_ view: AnyView, size: NSSize, dark: Bool, to file: URL) throws {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.layoutSubtreeIfNeeded()
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        let png = try #require(image.representation(using: .png, properties: [:]))
        try png.write(to: file)
        #expect(image.pixelsWide >= Int(size.width))
    }
}
