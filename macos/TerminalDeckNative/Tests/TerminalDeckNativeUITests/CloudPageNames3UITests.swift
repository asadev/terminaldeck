import Foundation
import Testing
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

/// Page-names 3 (real check 4 on a0b564c2), the window side: every device row of Settings → Cloud reads the same way;
/// "Trusted" only under the stricter trust setting; no picture name is read out as text; saved passwords off is one
/// sentence and one button.
@Suite("Cloud pages, round 3 — rows alike, no picture names, one sentence")
@MainActor
struct CloudPageNames3UITests {
    static let mini = "33333333-3333-4333-8333-333333333333"
    static let book = "44444444-4444-4444-8444-444444444444"
    static let key = CloudPublicJWK(kty: "EC", crv: "P-256", x: "x", y: "y")
    let now: Int64 = 1_794_000_000_000
    var nowDate: Date { Date(timeIntervalSince1970: Double(now) / 1000) }
    static let symbolNames = ["icloud", "laptopcomputer", "desktopcomputer", "brain", "folder", "person.2", "doc.text", "gearshape", "key", "tray",
                              "checkmark.circle", "arrow.triangle", "hourglass", "wifi.slash", "minus.circle", "exclamationmark"]

    func device(_ id: String, _ label: String, seen: Int64, pulledAt: Int64?) -> CloudDevice {
        var made = CloudDevice(deviceId: id, label: label, platform: .macos, appVersion: "fixture", status: .active, secretsApproved: false,
                               lastSeenAt: seen, signPublicJwk: Self.key, wrapPublicJwk: Self.key, registeredAt: now - 86_400_000)
        made.lastPulledAt = pulledAt
        return made
    }
    /// The real shape: this Mac's trust row carries no added date; the other Mac's row is under another id than the
    /// service's entry (only "Trusted" was shown for it).
    var rows: [CloudDeviceTrustRow] {
        [CloudDeviceTrustRow(deviceId: Self.book, name: "asads-macbook-pro-21.local", standing: .thisMac, code: "AAAA BBBB CCCC DDDD", keyId: "k1", signKey: Self.key),
         CloudDeviceTrustRow(deviceId: "trust-row-of-the-mini", name: "imatch-mac-mini.local", standing: .trusted, code: "EEEE FFFF GGGG HHHH",
                             keyId: "k2", signKey: Self.key, knownSince: now - 40_000_000)]
    }
    var devices: [CloudDevice] {
        // The service's hourly check-in is old; its reported read time is 2 minutes ago.
        [device(Self.mini, "imatch-mac-mini.local", seen: now - 3_600_000, pulledAt: now - 120_000),
         device(Self.book, "asads-macbook-pro-21.local", seen: now - 60_000, pulledAt: nil)]
    }

    // P3. Name · "Added <date>" · "Last seen <date, time>" for both devices; "This Mac" on its own row; "Trusted" only
    // under "Ask me for each new device".
    @Test func everyDeviceRowReadsTheSameWay() throws {
        for row in rows {
            let entry = try #require(NativeCloudDevicePlainRow.device(for: row, in: devices))
            let added = row.addedAt ?? entry.registeredAt ?? row.knownSince
            let seen = try #require(NativeCloudDevicePlainRow.lastSeen(entry))
            let dates = NativeCloudDevicePlainRow.dates(added: added, lastSeen: seen, now: nowDate)
            #expect(dates.hasPrefix("Added "), "\(dates)")
            #expect(dates.contains(" · Last seen Today, "), "\(dates)")
            for ask in [false, true] {
                let spoken = NativeCloudDevicePlainRow.spoken(row, added: added, lastSeen: seen, askMode: ask, now: nowDate)
                #expect(spoken.hasPrefix(row.name + ", Added "))
                for name in Self.symbolNames { #expect(!spoken.lowercased().contains(name), "\(spoken)") }
            }
        }
        // The Mac mini's "last seen" is its reported read time (2 minutes ago), not the hourly check-in.
        let miniEntry = try #require(NativeCloudDevicePlainRow.device(for: rows[1], in: devices))
        #expect(miniEntry.deviceId == Self.mini)
        #expect(NativeCloudDevicePlainRow.lastSeen(miniEntry) == now - 120_000)
        // The word on the right.
        #expect(NativeCloudDevicePlainRow.state(rows[0], askMode: false) == "This Mac")
        #expect(NativeCloudDevicePlainRow.state(rows[0], askMode: true) == "This Mac")
        #expect(NativeCloudDevicePlainRow.state(rows[1], askMode: false) == "")
        #expect(NativeCloudDevicePlainRow.state(rows[1], askMode: true) == "Trusted")
        let automatic = rows.map { NativeCloudDevicePlainRow.spoken($0, added: now - 86_400_000, lastSeen: now - 60_000, askMode: false, now: nowDate) }
        #expect(!automatic.contains { $0.contains("Trusted") })
        #expect(automatic[0].hasSuffix(", This Mac"))
    }

    // P4. No picture is read out by its name: every picture in both views is hidden from accessibility (the headline,
    // card label or text beside it says what it means), and the empty window reads only "Checking…".
    @Test func noPictureNameLeaksIntoTheText() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["NativeCloudContents.swift", "NativeCloudOverview.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent("Sources/TerminalDeckNative/" + file), encoding: .utf8)
            let pictures = source.components(separatedBy: "Image(systemName:").count - 1
            let hidden = source.components(separatedBy: ".accessibilityHidden(true)").count - 1
            #expect(pictures > 0 && hidden >= pictures, "\(file): \(pictures) pictures, \(hidden) hidden")
        }
        #expect(BackendCloudOverviewWords.checking == "Checking…")
        // The empty window's picture is the one real check 4 heard as "Icloud".
        let contents = try String(contentsOf: root.appendingPathComponent("Sources/TerminalDeckNative/NativeCloudContents.swift"), encoding: .utf8)
        #expect(contents.contains("Image(systemName: \"icloud\").font(.system(size: 32)).foregroundStyle(DeckTokens.textSecondary).accessibilityHidden(true)"))
    }

    // P1 (owner, 14 Nov: on by default): while this Mac makes the key it says "Turning on"; the summary above it has
    // nothing about saved passwords, and recovery words are offered only under "Older accounts".
    @Test func savedPasswordsOffIsOneSentenceAndOneButton() throws {
        #expect(BackendCloudSecretsWords.state({ var p = BackendCloudSecretsPage(); p.standing = .notSetUp; return p }()) == "Turning on")
        // His page rule: one state and at most ONE control.
        var waiting = BackendCloudSecretsPage(); waiting.standing = .locked; waiting.opensBySelf = true
        #expect(NativeCloudSecretsSection.control(for: waiting) == .none)
        var dead = BackendCloudSecretsPage(); dead.standing = .locked; dead.cannotOpen = true; dead.startAgainAvailable = true
        #expect(NativeCloudSecretsSection.control(for: dead) == .startAgain)
        // PASSWORDS-2: "Start again" waits 5 seconds behind Undo; the line says so and the one control is Undo.
        var starting = dead; starting.startingAgain = true
        #expect(NativeCloudSecretsSection.control(for: starting) == .undoStartAgain)
        #expect(BackendCloudSecretsWords.state(starting) == "Starting again…")
        // The stricter setting: a new Mac's one waiting line; nothing to press there.
        var click = waiting; click.waitsForClick = true
        #expect(BackendCloudSecretsWords.state(click) == "Allow this Mac on one of your other devices")
        #expect(NativeCloudSecretsSection.control(for: click) == .none)
        var silent = BackendCloudSecretsPage(); silent.standing = .locked
        #expect(NativeCloudSecretsSection.control(for: silent) == .ask)
        var older = silent; older.offersRecoveryWords = true
        #expect(NativeCloudSecretsSection.control(for: older) == .askOrWords)
        var on = BackendCloudSecretsPage(); on.standing = .protected
        #expect(NativeCloudSecretsSection.control(for: on) == .none)
        // INT2 (moved from CloudSecretsPasskeySpareTests, which cannot see the app target): his passkey opens the copy.
        var passkeyWaits = BackendCloudSecretsPage(); passkeyWaits.standing = .locked; passkeyWaits.waitsForClick = true; passkeyWaits.opensWithPasskey = true
        #expect(NativeCloudSecretsSection.control(for: passkeyWaits) == .openWithPasskey)
        var passkeyDead = BackendCloudSecretsPage(); passkeyDead.standing = .locked; passkeyDead.cannotOpen = true; passkeyDead.startAgainAvailable = true; passkeyDead.opensWithPasskey = true
        #expect(NativeCloudSecretsSection.control(for: passkeyDead) == .openWithPasskey)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let overview = try String(contentsOf: root.appendingPathComponent("Sources/TerminalDeckNative/NativeCloudOverview.swift"), encoding: .utf8)
        #expect(!overview.contains("notSavedTitle") && !overview.contains("notSavedInThisVersion"))
        var off = BackendCloudSecretsPage()
        off.standing = .notSetUp
        let snapshot = CloudAccountSnapshot(phase: .signedIn, gate: CloudGate(features: ["cloud"], storageEntitled: true), displayName: "Fixture",
                                            coverage: [CloudCoverage(sourceId: "memory/I01", inventoryRow: "I01", complete: true, items: 3, bytes: 10, blockedReasons: [])],
                                            cloudHead: CloudSequence(5), fetched: CloudSequence(5))
        let summary = try #require(BackendCloudOverviewBuilder.build(BackendCloudOverviewInput(snapshot: snapshot, memory: .init(included: true), passwords: off)))
        let texts = [summary.title] + summary.lines + summary.waiting.map(\.text) + summary.notices.map(\.text) + summary.rows.flatMap { [$0.title, $0.state] + $0.notes }
        #expect(!texts.contains { $0.localizedCaseInsensitiveContains("saved passwords") || $0 == "Off on this Mac" || $0 == "Not saved in this version" })
    }
}
