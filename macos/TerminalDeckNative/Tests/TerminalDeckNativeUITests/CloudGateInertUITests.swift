import AppKit
import SwiftUI
import Foundation
import Testing
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

/// AM8 / S18: with no account, the gate off, or after sign-out, nothing of Cloud is constructed at launch.
@Suite("Cloud gate off — dormant launch constructs nothing", .serialized)
@MainActor
struct CloudGateInertUITests {
    private static var approvedRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Deck Dev/notes/cloud-test-20261112", isDirectory: true).resolvingSymlinksInPath()
    }
    @MainActor private final class Calls { var count = 0 }

    @Test func aFolderWithoutAccountStateNeverConstructsTheAccount() async throws {
        let data = Self.approvedRoot.appendingPathComponent("a-gate-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        var clock: UInt64 = 1_000_000_000_000
        NativeCloudAccount.shared.monotonic = { clock }
        defer { try? FileManager.default.removeItem(at: data); NativeCloudAccount.shared.detach(); NativeCloudAccount.shared.asker = { _, _, _ in false }
                NativeCloudAccount.shared.monotonic = { BackendCloudAccount.monotonicNow() } }
        let before = try FileManager.default.contentsOfDirectory(atPath: data.path)
        let calls = Calls()
        let account = await NativeCloudLaunch.begin(dataRoot: data) { calls.count += 1; return nil }
        #expect(account == nil)
        #expect(calls.count == 0)
        // No file or folder appears, no navigation, screen or visible page exists.
        #expect(try FileManager.default.contentsOfDirectory(atPath: data.path) == before)
        #expect(!NativeCloudLaunch.used(dataRoot: data))
        // A copy that cannot sign in (no public key, as in every test process) lists no Cloud section at all.
        #expect(!NativeCloudDisplayGate.shared.get())
        #expect(!NativeCloudDisplayGate.shared.shows)
        #expect(!NativeSettingsNavigation.items.contains { $0.id == "cloud" })
        #expect(!NativeScreens.registered.contains("settings:cloud"))
        #expect(!NativeCloudAccount.shared.visible)
        // Owner, 13 Nov: the website's sign-in link starts the sign-in without a question (it is the person's own
        // press on the website). A return link that answers no sign-in of this app builds nothing at all.
        let model = NativeCloudAccount.shared, asked = Calls()
        model.asker = { _, _, _ in asked.count += 1; return false }
        #expect(model.handle(URL(string: "terminaldeck://cloud/return/AAAAAAAAAAAAAAAAAAAAAA?code=x&state=y")!))
        for _ in 0..<50 { await Task.yield() }
        #expect(calls.count == 0)
        #expect(model.handle(URL(string: "terminaldeck://cloud/signin")!))
        for _ in 0..<50 where calls.count == 0 { await Task.yield() }
        #expect(calls.count == 1)
        // At most one link-started sign-in every 30 seconds.
        #expect(model.handle(URL(string: "terminaldeck://cloud/signin")!))
        for _ in 0..<50 { await Task.yield() }
        #expect(calls.count == 1)
        clock += 31_000_000_000
        // Unrelated links are untouched; only the person's own sign-in link wakes the account, once.
        #expect(!NativeCloudAccount.shared.handle(URL(string: "terminaldeck://cloud/other")!))
        #expect(NativeCloudAccount.shared.handle(URL(string: "terminaldeck://cloud/signin")!))
        for _ in 0..<50 where calls.count == 1 { await Task.yield() }
        #expect(calls.count == 2)
        #expect(asked.count == 0)
        // A refused factory stays dormant and creates nothing.
        #expect(try FileManager.default.contentsOfDirectory(atPath: data.path) == before)
        NativeCloudAccount.shared.detach()
        #expect(!NativeCloudAccount.shared.handle(URL(string: "terminaldeck://cloud/signin")!))
    }

    /// 0.22.1: a copy that can sign in lists Settings → Cloud while signed out, with one sentence and one Sign in
    /// button. Listing and drawing it builds nothing: no activation, no question, no file or folder, no open gate.
    @Test func signedOutSettingsShowOnlyTheSignInButtonAndConstructNothing() async throws {
        let data = Self.approvedRoot.appendingPathComponent("a-gate-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let model = NativeCloudAccount.shared
        defer { try? FileManager.default.removeItem(at: data); model.detach(); NativeCloudDisplayGate.shared.offer(false)
                model.asker = { _, _, _ in false } }
        let before = try FileManager.default.contentsOfDirectory(atPath: data.path)
        let calls = Calls(), asked = Calls()
        model.asker = { _, _, _ in asked.count += 1; return true }
        NativeCloudDisplayGate.shared.offer(true)
        let account = await NativeCloudLaunch.begin(dataRoot: data) { calls.count += 1; return nil }
        #expect(account == nil)
        // The section is listed, with its modest line; the open-Cloud gate stays shut.
        let item = NativeSettingsNavigation.item("cloud") // inside Profile since 15 Nov
        #expect(item?.description == "Sign in to keep your work on all your devices.")
        #expect(NativeSettingsNavigation.canonical("cloud") == "cloud")
        #expect(NativeScreens.registered.contains("settings:cloud"))
        #expect(!NativeCloudDisplayGate.shared.get())
        #expect(!model.visible)
        #expect(model.signInStage == .signedOut(waiting: false))
        let content = NativeCloudSignInPage.content(model.signInStage)
        #expect(content.line == NativeCloudSignInPage.signedOutLine)
        #expect(content.line == "Sign in with your Terminal Deck account to keep your work on all your devices.")
        #expect(!content.line.contains("terminaldeck.dev"))
        #expect(content.button == "Sign in")
        #expect(content.enabled)
        // Drawing the page (both the router and the sign-in page) constructs nothing.
        let host = NSHostingView(rootView: NativeCloudPage(model: model).frame(width: 900, height: 680))
        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 900, height: 680)
        host.layoutSubtreeIfNeeded()
        if let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: image) }
        for _ in 0..<50 { await Task.yield() }
        #expect(calls.count == 0)
        #expect(asked.count == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: data.path) == before)
        #expect(!NativeCloudLaunch.used(dataRoot: data))
        #expect(NativeCloudBrainRegistration.current == nil)
        // The press is the agreement: the factory is asked once, no question; a refused factory stays signed out and armed.
        model.pressSignIn()
        for _ in 0..<50 where model.pressing { await Task.yield() }
        #expect(calls.count == 1)
        #expect(asked.count == 0)
        #expect(model.notice == "Could not open sign-in: this copy of Terminal Deck could not set up its Cloud account. Try again.")
        #expect(model.signInStage == .signedOut(waiting: false))
        #expect(try FileManager.default.contentsOfDirectory(atPath: data.path) == before)
    }
    /// Pressing Sign in builds the account once through the armed activation and starts the sign-in; a second press while
    /// that is in flight does nothing.
    @Test func pressingSignInActivatesOnceAndStartsTheFlow() async throws {
        let data = Self.approvedRoot.appendingPathComponent("a-gate-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let model = NativeCloudAccount.shared
        defer { try? FileManager.default.removeItem(at: data); model.detach(); model.starter = nil; model.asker = { _, _, _ in false } }
        let config = try CloudAccountConfiguration(baseURL: URL(string: "https://cloud.example.invalid/v1")!, issuer: "https://issuer.example.invalid/auth/v1",
            websiteStartURL: URL(string: "https://site.example.invalid/api/store/cloud/start")!, storeAuthURL: URL(string: "https://issuer.example.invalid/auth/v1")!,
            publishableKey: "fixture-public", deviceLabel: "Fixture Mac", appVersion: "fixture", environment: .fixture)
        let fixture = try NativeCloudApplication.assemble(configuration: config, dataRoot: data,
            protectedStore: .init(read: { nil }, write: { _ in }, remove: {}), trustSlot: { _ in .init(read: { nil }, write: { _ in }) })
        let calls = Calls(), started = Calls(), asked = Calls(), release = Calls()
        model.asker = { _, _, _ in asked.count += 1; return true }
        model.starter = { started.count += 1 }
        model.arm({ calls.count += 1; while release.count == 0 { await Task.yield() }; return fixture })
        model.pressSignIn()
        #expect(model.pressing)
        #expect(model.signInStage == .signedOut(waiting: true))
        let waiting = NativeCloudSignInPage.content(model.signInStage)
        #expect(waiting.button == "Signing in…")
        #expect(!waiting.enabled)
        for _ in 0..<50 where calls.count == 0 { await Task.yield() }
        model.pressSignIn()
        for _ in 0..<20 { await Task.yield() }
        #expect(calls.count == 1)
        #expect(started.count == 0)
        release.count = 1
        for _ in 0..<200 where started.count == 0 { await Task.yield() }
        #expect(calls.count == 1)
        #expect(started.count == 1)
        #expect(asked.count == 0)
        #expect(!model.pressing)
    }

    @Test func signingOutReturnsTheNextLaunchToTheNoAccountState() async throws {
        let data = Self.approvedRoot.appendingPathComponent("a-gate-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: NativeCloudLaunch.folder(data), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: data); NativeCloudAccount.shared.detach() }
        #expect(NativeCloudLaunch.used(dataRoot: data))
        let calls = Calls()
        _ = await NativeCloudLaunch.begin(dataRoot: data) { calls.count += 1; return nil }
        #expect(calls.count == 1)
        NativeCloudLaunch.recordSession(.signedOut, dataRoot: data)
        #expect(!NativeCloudLaunch.used(dataRoot: data))
        _ = await NativeCloudLaunch.begin(dataRoot: data) { calls.count += 1; return nil }
        #expect(calls.count == 1)
        NativeCloudLaunch.recordSession(.signedIn, dataRoot: data)
        #expect(NativeCloudLaunch.used(dataRoot: data))
    }

    @Test func aRefusedFactoryStillLeavesTheSignInLinkArmed_finding25() async throws {
        let data = Self.approvedRoot.appendingPathComponent("a-gate-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: NativeCloudLaunch.folder(data), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: data); NativeCloudAccount.shared.detach(); NativeCloudAccount.shared.asker = { _, _, _ in false } }
        let calls = Calls()
        NativeCloudAccount.shared.asker = { _, _, _ in true }
        let account = await NativeCloudLaunch.begin(dataRoot: data, activate: { calls.count += 1; return nil })
        #expect(account == nil)
        #expect(calls.count == 1)
        #expect(NativeCloudAccount.shared.handle(URL(string: "terminaldeck://cloud/signin")!))
        for _ in 0..<50 where calls.count == 1 { await Task.yield() }
        #expect(calls.count == 2)
    }
    @Test func aDormantAccountIsRecheckedAtMostOnceADayAndALinkOnlyRechecksQuietly_N3_N5() async throws {
        let data = Self.approvedRoot.appendingPathComponent("a-gate-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: NativeCloudLaunch.folder(data), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: data); NativeCloudAccount.shared.detach(); NativeCloudAccount.shared.asker = { _, _, _ in false } }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        NativeCloudLaunch.recordSession(.dormant, dataRoot: data, now: now)
        #expect(!NativeCloudLaunch.used(dataRoot: data, now: now.addingTimeInterval(3_600)))
        #expect(NativeCloudLaunch.used(dataRoot: data, now: now.addingTimeInterval(86_401)))
        #expect(NativeCloudLaunch.isDormant(dataRoot: data))
        // A link for a dormant account asks nothing; it only builds the account to re-check.
        let asked = Calls(), calls = Calls()
        NativeCloudAccount.shared.asker = { _, _, _ in asked.count += 1; return true }
        NativeCloudAccount.shared.arm({ calls.count += 1; return nil }, dormant: true)
        #expect(NativeCloudAccount.shared.handle(URL(string: "terminaldeck://cloud/signin")!))
        for _ in 0..<50 where calls.count == 0 { await Task.yield() }
        #expect(calls.count == 1)
        #expect(asked.count == 0)
        // Signing in again clears the dormant marker.
        NativeCloudLaunch.recordSession(.signedIn, dataRoot: data)
        #expect(!NativeCloudLaunch.isDormant(dataRoot: data))
    }
    @Test func memoryIsNeverIncludedWithoutTheRecordedChoice_section10() throws {
        let data = Self.approvedRoot.appendingPathComponent("a-gate-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: data) }
        let subject = String(repeating: "a", count: 64)
        #expect(!NativeCloudLaunch.memoryIncluded(dataRoot: data, subjectHash: subject))
        let file = NativeCloudLaunch.memoryChoiceFile(dataRoot: data, subjectHash: subject)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("local".utf8).write(to: file)
        #expect(!NativeCloudLaunch.memoryIncluded(dataRoot: data, subjectHash: subject))
        try Data("include".utf8).write(to: file)
        #expect(NativeCloudLaunch.memoryIncluded(dataRoot: data, subjectHash: subject))
    }
    /// 0.22.0: exactly the proven rows (memory I01-I06, boot files I09, agents I10, projects I11) and their domains
    /// reach the sync engine, nothing else (no device path map). The engine itself is built only for a signed-in,
    /// allowed account; the rest of this suite proves nothing exists before that.
    @Test func onlyProvenRowsReachTheSyncEngine_finding27() throws {
        #expect(NativeCloudBrainRegistration.provenRows == ["I01", "I02", "I03", "I04", "I05", "I06", "I09", "I10", "I11", "I12", "I21", "I23", "I24"])
        let expected = Set(CloudBrainMemoryFormat.inventoryRows.map(CloudBrainMemoryFormat.domain))
            .union([CloudBrainFilesFormat.domain(CloudBootFilesFormat.inventoryRow)])
            .union(try BackendCloudLeanRecords.domains(BackendCloudLeanRecords.rows))
            .union(try BackendCloudKinds.domains(BackendCloudKinds.rows))
            .union([CloudFolderFormat.domain, CloudArtifactsFormat.domain])
        #expect(NativeCloudBrainRegistration.brainDomains == expected)
        #expect(!NativeCloudBrainRegistration.brainDomains.contains("machines/paths"))
    }
    @Test func recordingASignOutNeverCreatesTheCloudFolder() throws {
        let data = Self.approvedRoot.appendingPathComponent("a-gate-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: data) }
        NativeCloudLaunch.recordSession(.signedOut, dataRoot: data)
        #expect(!FileManager.default.fileExists(atPath: NativeCloudLaunch.folder(data).path))
    }
}
