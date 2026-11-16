import AppKit
import SwiftUI
import Testing
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

@Suite("Cloud gate — real settings inventory and rendered frame", .serialized)
@MainActor
struct CloudGateUITests {
    /// A copy that cannot sign in (no public sign-in key, a read-only folder, a test process) lists no Cloud section.
    @Test func absentByDefaultAndUnknownRouteReturnsGeneral() {
        NativeCloudDisplayGate.shared.set(false)
        NativeCloudDisplayGate.shared.offer(false)
        #expect(!NativeSettingsNavigation.items.contains { $0.id == "cloud" })
        #expect(NativeSettingsNavigation.matching("Cloud").isEmpty)
        #expect(NativeSettingsNavigation.canonical("cloud") == "general")
        #expect(!NativeScreens.registered.contains("settings:cloud"))
        #expect(!NativeCloudAccount.shared.visible)
    }
    @Test func onlyACopyWithThePublicKeyOffersSignIn() {
        #expect(!NativeCloudApplication.canSignIn(testProcess: false, readOnly: false, appName: "Terminal Deck", publishableKey: nil, scratch: false))
        #expect(!NativeCloudApplication.canSignIn(testProcess: false, readOnly: false, appName: "Terminal Deck", publishableKey: "sb_secret_fixture", scratch: false))
        #expect(NativeCloudApplication.canSignIn(testProcess: false, readOnly: false, appName: "Terminal Deck", publishableKey: "sb_publishable_fixture", scratch: false))
        #expect(!NativeCloudApplication.canSignIn(testProcess: true, readOnly: false, appName: "Terminal Deck", publishableKey: "sb_publishable_fixture", scratch: true))
        #expect(!NativeCloudApplication.canSignIn(testProcess: false, readOnly: true, appName: "Terminal Deck", publishableKey: "sb_publishable_fixture", scratch: false))
        #expect(!NativeCloudApplication.canSignIn(testProcess: false, readOnly: false, appName: nil, publishableKey: "sb_publishable_fixture", scratch: false))
        NativeCloudDisplayGate.shared.offer(false)
        #expect(!NativeSettingsNavigation.items.contains { $0.id == "cloud" })
    }
    /// Signed in, but the service does not open Cloud for this account: one sentence and Sign out, no Cloud page.
    @Test func notAllowedStateShowsTheSentenceAndSignOut() throws {
        let model = NativeCloudAccount()
        model.fixtureSnapshot(.init(phase: .dormant, gate: .closed, displayName: "person@example.com", problem: "Cloud is not available for this account."))
        #expect(!model.visible)
        #expect(model.signInStage == .notOpen(name: "person@example.com"))
        let content = NativeCloudSignInPage.content(model.signInStage)
        #expect(content.line == "You are signed in as person@example.com. Cloud is not open for this account yet.")
        #expect(content.button == "Sign out")
        #expect(content.enabled)
        model.fixtureSnapshot(.init(phase: .signedIn, gate: .closed, displayName: "person@example.com"))
        #expect(model.signInStage == .notOpen(name: "person@example.com"))
        let host = NSHostingView(rootView: NativeCloudPage(model: model).frame(width: 900, height: 680))
        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 900, height: 680)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width >= 0)
    }
    @Test func aFailedCloudFactoryDoesNotFailTheAppGraph() async {
        let result = await NativeCompositionCloud.resolveAccount { throw CloudFailure.unavailable }
        #expect(result == nil)
        #expect(!NativeCloudDisplayGate.shared.get())
    }
    @Test func eligibleFixtureHasOnePageAndRendersBothThemes() throws {
        let model = NativeCloudAccount.shared
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let key = CloudPublicJWK(kty: "EC", crv: "P-256", x: "fixture", y: "fixture")
        let gate = CloudGate(features: ["cloud"], storageEntitled: true, aiSubscriptionsEnabled: false, revision: CloudSequence(1), expiresAt: now + 300_000)
        let snapshot = CloudAccountSnapshot(phase: .signedIn, gate: gate, displayName: "Fixture person", devices: [
            .init(deviceId: "fixture-a", label: "Fixture Mac A", platform: .macos, appVersion: "fixture", status: .active, secretsApproved: false, lastSeenAt: now, signPublicJwk: key, wrapPublicJwk: key),
            .init(deviceId: "fixture-b", label: "Fixture Mac B", platform: .macos, appVersion: "fixture", status: .active, secretsApproved: false, lastSeenAt: now, signPublicJwk: key, wrapPublicJwk: key)
        ], coverage: [.init(sourceId: "fixture-source", inventoryRow: "I01", complete: true, items: 3, bytes: 20, blockedReasons: [])], waitingRecords: 2)
        model.fixture(snapshot)
        defer { model.fixture(.signedOut) }
        #expect(NativeSettingsNavigation.item("cloud")?.id == "cloud") // inside Profile since 15 Nov
        #expect(NativeScreens.registered.filter { $0 == "settings:cloud" }.count == 1)
        // Rendered proof goes under the agreed scratch root whatever launched the tests (no runner environment needed).
        let approved = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Deck Dev/notes/cloud-test-20261112").resolvingSymlinksInPath()
        let root = approved.appendingPathComponent("a-gate-render-" + UUID().uuidString + "/proof")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for dark in [false, true] {
            let view = NativeCloudSettings(model: model).environment(\.colorScheme, dark ? .dark : .light).frame(width: 900, height: 680)
            let host = NSHostingView(rootView: view)
            host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 900, height: 680)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.layoutSubtreeIfNeeded()
            let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            let png = try #require(image.representation(using: .png, properties: [:]))
            try png.write(to: root.appendingPathComponent("cloud-settings-\(dark ? "dark" : "light").png"))
            #expect(image.pixelsWide >= 900 && image.pixelsHigh >= 680)
        }
        model.fixture(.signedOut)
        #expect(!NativeSettingsNavigation.items.contains { $0.id == "cloud" })
        #expect(!NativeScreens.registered.contains("settings:cloud"))
    }
}
