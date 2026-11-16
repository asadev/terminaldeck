import AppKit
import Foundation
import CryptoKit
import Testing
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

/// 13 Nov: "Could not open sign-in. Try again." on both of the owner's Macs. The production press path (armed activation
/// that attaches the service, no fixture `starter`, the real loopback listener, the real Keychain read) had never run.
/// Part of the gate suite on purpose: every test here drives `NativeCloudAccount.shared`, so they run serialized with it.
extension CloudGateInertUITests {
    private static var signInRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Deck Dev/notes/cloud-test-20261112", isDirectory: true).resolvingSymlinksInPath()
    }
    @MainActor final class Box<T> { var value: T; init(_ value: T) { self.value = value } }

    private static func fixtureConfiguration() throws -> CloudAccountConfiguration {
        try CloudAccountConfiguration(baseURL: URL(string: "https://cloud.example.invalid/v1")!, issuer: "https://issuer.example.invalid/auth/v1",
            websiteStartURL: URL(string: "https://site.example.invalid/api/store/cloud/start")!, storeAuthURL: URL(string: "https://issuer.example.invalid/auth/v1")!,
            publishableKey: "fixture-public", deviceLabel: "Fixture Mac", appVersion: "fixture", environment: .fixture)
    }

    /// The press goes exactly as in the app: the activation builds and attaches the account, then `signIn()` reads
    /// the Keychain (a throwaway service, read only: nothing is written) and opens the browser on the official
    /// website's start address with the app callback (owner, 13 Nov: no loopback listener, no port).
    @Test func pressingSignInOpensTheBrowserWithTheAppCallback() async throws {
        let data = Self.signInRoot.appendingPathComponent("a-signin-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let model = NativeCloudAccount.shared
        let notes = Box<[String]>([])
        let previousLog = NativeCloudAccount.log
        NativeCloudAccount.log = { notes.value.append($0) }
        defer { try? FileManager.default.removeItem(at: data); model.detach(); NativeCloudAccount.log = previousLog; model.useSignInOpener { NSWorkspace.shared.open($0) } }
        let account = try NativeCloudApplication.assemble(configuration: try Self.fixtureConfiguration(), dataRoot: data,
            protectedStore: .keychain(appName: "Terminal Deck sign-in probe", instanceId: UUID().uuidString),
            trustSlot: { _ in .init(read: { nil }, write: { _ in }) })
        let opened = Box<URL?>(nil)
        model.arm({ model.attach(account, openURL: { opened.value = $0 }); return account })
        model.pressSignIn()
        for _ in 0..<500 where opened.value == nil && model.notice == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.notice == nil, "notice: \(model.notice ?? "")")
        #expect(notes.value == ["cloud sign-in: start ok"], "log: \(notes.value)")
        let url = try #require(opened.value)
        #expect(url.host == "site.example.invalid")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "callback" }?.value?.count == 22)
        #expect(items.first { $0.name == "state" }?.value?.count == 43)
        #expect(items.first { $0.name == "platform" }?.value == "macos")
        #expect(items.first { $0.name == "port" } == nil)
    }

    private static func scratchAccount(_ data: URL) throws -> BackendCloudAccount {
        try NativeCloudApplication.assemble(configuration: try fixtureConfiguration(), dataRoot: data,
            protectedStore: .init(read: { nil }, write: { _ in }, remove: {}), trustSlot: { _ in .init(read: { nil }, write: { _ in }) })
    }
    /// Owner, 13 Nov: a `terminaldeck://cloud/return/…` link that does not answer this app's own pending sign-in
    /// changes nothing, shows nothing and is logged as one plain line (never its token, code or state). The same
    /// link again (a replay) does the same.
    @Test func aReturnLinkThatIsNotThisAppsSignInDoesNothing() async throws {
        let data = Self.signInRoot.appendingPathComponent("a-return-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let model = NativeCloudAccount.shared
        let notes = Box<[String]>([])
        let previousLog = NativeCloudAccount.log
        NativeCloudAccount.log = { notes.value.append($0) }
        defer { try? FileManager.default.removeItem(at: data); model.detach(); NativeCloudAccount.log = previousLog; model.useSignInOpener { NSWorkspace.shared.open($0) } }
        let account = try Self.scratchAccount(data)
        let opened = Box<URL?>(nil)
        model.attach(account, openURL: { opened.value = $0 })
        let shown = NativeCloudSheetGuard.shared.shown
        let link = URL(string: "terminaldeck://cloud/return/AAAAAAAAAAAAAAAAAAAAAA?code=SECRETCODE&state=SECRETSTATE")!
        // No sign-in pending at all.
        #expect(model.handle(link))
        for _ in 0..<300 where notes.value.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(notes.value == ["cloud sign-in: return link ignored: not this app's sign-in"])
        // A sign-in of this app is pending, but the link carries another token and state; then the same link again.
        model.pressSignIn()
        for _ in 0..<500 where opened.value == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(opened.value != nil)
        notes.value = []
        #expect(model.handle(link))
        #expect(model.handle(link))
        for _ in 0..<300 where notes.value.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(notes.value == Array(repeating: "cloud sign-in: return link ignored: not this app's sign-in", count: 2))
        #expect(notes.value.allSatisfy { !$0.contains("SECRET") && !$0.contains("AAAAAAAA") })
        #expect(model.notice == nil)
        #expect(await account.hasPendingSignIn())
        #expect(model.snapshot.phase == .signingIn)
        #expect(NativeCloudSheetGuard.shared.shown == shown)
        // A malformed return link (extra items) is ignored the same way.
        notes.value = []
        #expect(model.handle(URL(string: "terminaldeck://cloud/return/AAAAAAAAAAAAAAAAAAAAAA?code=a&state=b&next=x")!))
        #expect(notes.value == ["cloud sign-in: return link ignored: not a sign-in link"])
    }
    /// Owner, 13 Nov: in "Automatically, with my account" no trust sheet, new-Mac sheet or question is ever shown,
    /// whatever asks for one; in "Ask me for each new device" the same call shows the new-Mac sheet as before.
    @Test func automaticModeNeverPresentsATrustSheet() async throws {
        let model = NativeCloudAccount.shared
        let sheets = NativeCloudTrustSheets.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let previousParent = sheets.parent
        sheets.parent = { window }
        let asked = Box(0)
        let previousAsker = model.asker
        model.asker = { _, _, _ in asked.value += 1; return false }
        defer { sheets.closeAll(); sheets.parent = previousParent; model.asker = previousAsker; model.useTrustMode(.ask); model.detach() }
        let point = P256.Signing.PrivateKey().publicKey.x963Representation
        let jwk = CloudPublicJWK(kty: "EC", crv: "P-256", x: BackendCloudAccountIdentity.base64(Data(point[1..<33])), y: BackendCloudAccountIdentity.base64(Data(point[33..<65])))
        let device = CloudDevice(deviceId: "10000000-0000-4000-8000-00000000000a", label: "MacBook Air", platform: .macos, appVersion: "fixture",
                                 status: .active, secretsApproved: false, lastSeenAt: 0, signPublicJwk: jwk, wrapPublicJwk: jwk)
        let rows = BackendCloudTrustRows.build(devices: [device], list: nil, thisDeviceId: nil)
        #expect(rows.first?.canBeTrusted == true)
        model.useTrustMode(.account)
        let shown = NativeCloudSheetGuard.shared.shown
        sheets.setUp(rows, all: rows, model: model)
        await sheets.ask(rows[0], model: model)
        model.openTrust(rows[0])
        model.reopenSetup()
        for _ in 0..<20 { await Task.yield() }
        #expect(NativeCloudSheetGuard.shared.shown == shown)
        #expect(!sheets.isOpen)
        #expect(asked.value == 0)
        // The control: in ask mode the very same call shows the new-Mac sheet through the guard.
        model.useTrustMode(.ask)
        sheets.setUp(rows, all: rows, model: model)
        #expect(NativeCloudSheetGuard.shared.shown == shown + 1)
        #expect(sheets.isOpen)
    }
    /// The Cloud page's device rows (owner, 13 Nov): a name, the dates and a plain state. No code anywhere on them.
    @Test func deviceRowsShowNamesDatesAndStatesOnly() throws {
        let point = P256.Signing.PrivateKey().publicKey.x963Representation
        let jwk = CloudPublicJWK(kty: "EC", crv: "P-256", x: BackendCloudAccountIdentity.base64(Data(point[1..<33])), y: BackendCloudAccountIdentity.base64(Data(point[33..<65])))
        let device = CloudDevice(deviceId: "10000000-0000-4000-8000-00000000000a", label: "MacBook Air", platform: .macos, appVersion: "fixture",
                                 status: .active, secretsApproved: false, lastSeenAt: 1_794_000_000_000, signPublicJwk: jwk, wrapPublicJwk: jwk, registeredAt: 1_793_000_000_000)
        let row = try #require(BackendCloudTrustRows.build(devices: [device], list: nil, thisDeviceId: nil).first)
        let code = try #require(row.code)
        let dates = NativeCloudDevicePlainRow.dates(added: row.addedAt, lastSeen: device.lastSeenAt)
        #expect(dates.hasPrefix("Added ") && dates.contains(" · Last seen "))
        for text in [row.name, dates, NativeCloudDevicePlainRow.state(row, askMode: false), NativeCloudDevicePlainRow.state(row, askMode: true),
                     NativeCloudSettings.trustModeNote(.account), NativeCloudSettings.devicesNote] {
            #expect(!text.contains(code) && !text.contains(row.deviceId) && !text.lowercased().contains("code"))
        }
        #expect(NativeCloudDevicePlainRow.state(row, askMode: false) == "Not trusted on this Mac")
        #expect(NativeCloudSettings.trustModeLabel(.account) == "Automatically, with my account")
        #expect(NativeCloudSettings.trustModeLabel(.ask) == "Ask me for each new device")
    }

    /// A refused activation names its step on the page and writes one plain line to the app's log.
    @Test func aFailedActivationIsLoggedWithItsStep() async throws {
        let model = NativeCloudAccount.shared
        let notes = Box<[String]>([])
        let previousLog = NativeCloudAccount.log
        NativeCloudAccount.log = { notes.value.append($0) }
        defer { model.detach(); NativeCloudAccount.log = previousLog }
        model.arm({ NativeCloudAccount.recordActivationFailure(.init(step: "account", kind: "unsafeConfiguration")); return nil })
        model.pressSignIn()
        for _ in 0..<500 where model.notice == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.notice?.hasPrefix("Could not open sign-in: ") == true)
        #expect(notes.value.contains { $0.hasPrefix("cloud sign-in: account failed: ") })
    }

    /// Owner, 14 Nov: Profile is the top row (its own group), then General and Cloud; Settings opens on General.
    @Test func settingsListProfileThenGeneralThenCloud() {
        NativeCloudDisplayGate.shared.offer(true)
        defer { NativeCloudDisplayGate.shared.offer(false) }
        // 15 Nov: Devices and Cloud are inside Profile.
        #expect(Array(NativeSettingsNavigation.items.prefix(2).map(\.id)) == ["profile", "general"])
        #expect(NativeSettingsNavigation.items[0].group < NativeSettingsNavigation.items[1].group)
        #expect(NativeSettingsNavigation.shown(nil) == "general")
    }
}
