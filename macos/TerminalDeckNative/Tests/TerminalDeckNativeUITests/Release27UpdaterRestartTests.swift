import AppKit
import Foundation
import SwiftUI
import XCTest
import TerminalDeckBackend
@testable import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Release 27: "Restart to update" never cuts an answer (Hoot mid-answer: it waits, then goes by itself),
/// the person can cancel the wait, and the side panel's × hides one version across launches.
private final class InstallCount: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor
final class Release27UpdaterRestartTests: XCTestCase {
    // The updater's log lines go to the engine log in the app; here they must not wake the app model
    // (AppModel.shared asks for the notification centre, which an xctest process has no bundle for).
    override func setUp() async throws { NativeCompositionRoot.noteSink = { _ in } }
    override func tearDown() async throws { NativeCompositionRoot.noteSink = nil }

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("r27-updater-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func receipt(_ root: URL) -> NativeStagedUpdate {
        let release = NativeUpdateRelease(schemaVersion: 1, channel: "native-mac", version: "999.0.0", bundleIdentifier: "fixture", architecture: "arm64",
            url: URL(string: "https://github.com/asadev/terminaldeck/releases/download/v999.0.0/terminaldeck-native-999.0.0-arm64.zip")!,
            sha512: "fixture", size: 1, releaseDate: "2026-11-03", releaseNotes: nil, sha256: nil,
            notesURL: URL(string: "https://github.com/asadev/terminaldeck/releases/tag/v999.0.0"), notarized: false)
        return NativeStagedUpdate(release: release, directory: root, archive: root.appendingPathComponent("update.zip"), bundle: root.appendingPathComponent("Fixture.app"))
    }

    func testRestartWaitsWhileHootAnswersThenGoesByItself() async throws {
        let root = try scratch(), staged = receipt(try scratch())
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: staged.directory) }
        let installs = InstallCount()
        let updater = NativeAppUpdater(dataRoot: root, operations: .init(feed: { staged.release }, stage: { _, _ in staged }, install: { _ in installs.add() }))
        var busy: String? = "Hoot is answering"
        updater.busyReason = { busy }
        _ = await updater.handle("update:check")
        XCTAssertEqual(updater.rawState["notesUrl"] as? String, "https://github.com/asadev/terminaldeck/releases/tag/v999.0.0")
        _ = await updater.handle("update:download")
        let waiting = await updater.handle("update:install")
        XCTAssertEqual(waiting?["phase"] as? String, "ready")
        XCTAssertEqual(waiting?["waitingFor"] as? String, "Hoot is answering")
        XCTAssertEqual(installs.value, 0, "a restart must not cut Hoot's answer")
        XCTAssertFalse(updater.relaunchOnQuit)
        busy = nil
        let deadline = Date().addingTimeInterval(5)
        while installs.value == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(installs.value, 1, "the restart goes by itself once Hoot is done")
        XCTAssertNil(updater.waitingFor)
        XCTAssertTrue(updater.relaunchOnQuit)
    }

    func testTheWaitingRestartCanBeCancelledAndNothingInstalls() async throws {
        let root = try scratch(), staged = receipt(try scratch())
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: staged.directory) }
        let installs = InstallCount()
        let updater = NativeAppUpdater(dataRoot: root, operations: .init(feed: { staged.release }, stage: { _, _ in staged }, install: { _ in installs.add() }))
        var busy: String? = "Hoot is answering"
        updater.busyReason = { busy }
        _ = await updater.handle("update:check"); _ = await updater.handle("update:download")
        await updater.requestRestart()
        XCTAssertNotNil(updater.waitingFor)
        updater.cancelRestart()
        XCTAssertNil(updater.waitingFor)
        busy = nil
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertEqual(installs.value, 0)
        XCTAssertEqual(updater.rawState["phase"] as? String, "ready", "the update stays ready for the next press")
    }

    func testDismissHidesThisVersionAcrossLaunchesAndAManualCheckBringsItBack() async throws {
        let root = try scratch(), staged = receipt(try scratch())
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: staged.directory) }
        let operations = BackendAppManualUpdateStrategy.Operations(feed: { staged.release }, stage: { _, _ in staged }, install: { _ in })
        let first = NativeAppUpdater(dataRoot: root, operations: operations)
        first.dismiss(version: "999.0.0")
        let card = NativeUpdateCardModel()
        let second = NativeAppUpdater(dataRoot: root, operations: operations)
        XCTAssertEqual(second.dismissedVersion, "999.0.0", "a new launch remembers the ×")
        second.card = card
        _ = await second.handle("update:check") // a check the person asked for
        XCTAssertNil(second.dismissedVersion)
        XCTAssertEqual(card.card(inAppSessions: 0)?.title, "Update available · 999.0.0")
        XCTAssertEqual(card.card(inAppSessions: 0)?.notesURL?.absoluteString, "https://github.com/asadev/terminaldeck/releases/tag/v999.0.0")
    }

    func testCheckingUpdateIsVisibleThroughTheCardAndToolsAndDuplicateRestartIsIgnored() async throws {
        let root = try scratch(), staged = receipt(try scratch())
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: staged.directory) }
        let installs = InstallCount()
        let updater = NativeAppUpdater(dataRoot: root, operations: .init(feed: { staged.release }, stage: { _, _ in staged }, install: { _ in
            installs.add()
            try await Task.sleep(for: .milliseconds(200))
        }))
        let card = NativeUpdateCardModel(); updater.card = card
        _ = await updater.handle("update:check"); _ = await updater.handle("update:download")
        let restart = Task { await updater.requestRestart() }
        while !updater.checkingUpdate { await Task.yield() }
        XCTAssertEqual(updater.rawState["checkingUpdate"] as? Bool, true)
        XCTAssertEqual(card.card(inAppSessions: 0)?.title, "Checking the update…")
        XCTAssertTrue(card.card(inAppSessions: 0)?.busy == true)
        XCTAssertNil(card.card(inAppSessions: 0)?.primary)
        _ = await updater.handle("update:install")
        await restart.value
        XCTAssertEqual(installs.value, 1)
        XCTAssertFalse(updater.checkingUpdate)
    }

    func testFailedInstallLeavesTheAppOpenAndShowsTheCheckFailure() async throws {
        let root = try scratch(), staged = receipt(try scratch())
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: staged.directory) }
        let updater = NativeAppUpdater(dataRoot: root, operations: .init(feed: { staged.release }, stage: { _, _ in staged }, install: { _ in
            throw NativeUpdateFeed.Failure("The update could not be installed: archive SHA-256 changed after download. The app is still running.")
        }))
        let card = NativeUpdateCardModel(); updater.card = card
        _ = await updater.handle("update:check"); _ = await updater.handle("update:download")
        _ = await updater.handle("update:install")
        XCTAssertEqual(updater.state.phase, "error")
        XCTAssertFalse(updater.relaunchOnQuit)
        XCTAssertFalse(updater.checkingUpdate)
        XCTAssertTrue(card.card(inAppSessions: 0)?.detail?.contains("SHA-256") == true)
        XCTAssertTrue(updater.prepareForQuit(), "an ordinary quit remains available after the refused update")
    }

    /// The card as the side panel draws it, just above the Settings row, in both appearances: pictures for review
    /// in macos/design-2026-10-10/built.noindex/R27-update-card-*.png.
    func testTheCardRendersEveryStateAboveSettings() throws {
        let notes = URL(string: "https://github.com/asadev/terminaldeck/releases/tag/v0.21.0")
        let states: [(String, UpdateState, String?, Bool)] = [
            ("available", .available(version: "0.21.0", notes: nil, sizeBytes: 89_442_281), nil, false),
            ("downloading", .downloading(version: "0.21.0", percent: 42, bytesPerSecond: 3_200_000), nil, false),
            ("ready", .ready(version: "0.21.0"), nil, false),
            ("waiting", .ready(version: "0.21.0"), "Hoot is answering", false),
            ("checking-update", .ready(version: "0.21.0"), nil, true),
            ("restarting", .ready(version: "0.21.0"), nil, true),
            ("error", .error(message: "The native update failed its SHA-256 check. Nothing was installed."), nil, false),
        ]
        let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("design-2026-10-10/built.noindex", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for dark in [false, true] {
            for (name, state, waiting, restarting) in states {
                let model = NativeUpdateCardModel()
                model.show(state, waitingFor: waiting, restarting: restarting, notesURL: notes, checkingUpdate: name == "checking-update")
                XCTAssertNotNil(model.card(inAppSessions: 0), name)
                let panel = VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    NativeUpdateCard(model: model, inAppSessions: { 0 })
                    Label("Settings", systemImage: "gearshape").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 20)
                        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
                }
                .font(.system(size: 13)).frame(width: 264, height: 230).background(DeckTokens.frame)
                .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: panel)
                host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 264, height: 230)
                let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
                host.appearance = appearance
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: out.appendingPathComponent("R27-update-card-\(name)-\(dark ? "dark" : "light").png"), options: .atomic)
            }
        }
    }
}
