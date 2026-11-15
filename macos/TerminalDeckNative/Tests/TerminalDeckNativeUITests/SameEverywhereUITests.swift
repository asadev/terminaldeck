import AppKit
import SwiftUI
import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Same everywhere (owner, 15 Nov): the Cloud line and its Sync now are no longer in the side panel ("Just keep it
/// inside the settings. Inside the cloud section"); they sit at the top of Settings › Cloud, with the one compact list
/// "Keep in sync on this Mac". Pictures drawn offscreen (never in a window) into
/// `night/codex/same-everywhere-evidence/`, light and dark.
@MainActor
final class SameEverywhereUITests: XCTestCase {
    private var package: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func source(_ name: String) throws -> String {
        try String(contentsOf: package.appendingPathComponent("Sources/TerminalDeckNative/" + name), encoding: .utf8)
    }
    static let gate = CloudGate(features: ["cloud"], storageEntitled: true)

    func testTheSidePanelHasNoStatusLineAndSettingsCloudHasItWithTheList() throws {
        let sidebar = try source("SidebarView.swift")
        XCTAssertFalse(sidebar.contains("SidebarCloudStatus(open:"), "no line in the side panel")
        XCTAssertTrue(sidebar.contains("footer().frame(height: 44)"), "the Profile row and the Settings button stay as they are")
        let page = try source("NativeCloudSettings.swift")
        let line = try XCTUnwrap(page.range(of: "NativeCloudSettingsStatusRow(line: Self.statusLine(line, devices: devices)"))
        let summary = try XCTUnwrap(page.range(of: "NativeCloudOverviewSection(overview:"))
        XCTAssertLessThan(line.lowerBound, summary.lowerBound, "the line is at the top of the page")
        XCTAssertTrue(page.contains("NativeCloudSyncChoicesSection(cloudOn:"))
        XCTAssertEqual(page.components(separatedBy: "Button(\"Sync now\")").count, 2, "one Sync now")
    }

    func testTheCloudItemsSmallMarkIsAllThatNeedsHimSays() {
        typealias W = BackendCloudStatusLineWords
        XCTAssertNil(NativeCloudStatusWatch.mark(.init(kind: .level, text: W.level(Date(), now: Date()), canSyncNow: true, levelAt: Date())))
        XCTAssertNil(NativeCloudStatusWatch.mark(.init(kind: .sending, text: W.sending(3), canSyncNow: true)))
        XCTAssertEqual(NativeCloudStatusWatch.mark(.init(kind: .signedOut, text: W.signedOut))?.status, "attention")
        XCTAssertEqual(NativeCloudStatusWatch.mark(.init(kind: .needsYou, text: W.needsYou([W.device]), needs: [W.device], canSyncNow: true))?.status, "attention")
        XCTAssertEqual(NativeCloudStatusWatch.mark(.init(kind: .problem, text: W.unreachable, canSyncNow: true))?.status, "failed")
    }

    func testTheListIsOnByDefaultAndKeptOnThisDeviceOnly() throws {
        let model = NativeCloudSyncChoices()
        for kind in CloudSyncKind.shown { XCTAssertTrue(model.isOn(kind), kind.title) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("same-everywhere-ui-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        model.use(dataRoot: root)
        model.set(.tasks, on: false)
        XCTAssertFalse(NativeCloudSyncChoices.isOn(.tasks, dataRoot: root))
        XCTAssertTrue(NativeCloudSyncChoices.isOn(.memory, dataRoot: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: NativeCloudLaunch.folder(root).appendingPathComponent(CloudSyncChoices.fileName).path),
                      "beside, not inside, the account folders")
        model.set(.tasks, on: true)
        XCTAssertTrue(NativeCloudSyncChoices.isOn(.tasks, dataRoot: root))
    }

    // MARK: Pictures

    func testPicturesOfTheSidePanelAndSettingsCloudBothThemes() throws {
        let output = package.deletingLastPathComponent().appendingPathComponent("night/codex/same-everywhere-evidence")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let account = NativeCloudAccount.shared
        defer { account.fixture(.signedOut); account.fixtureUser(nil) }
        account.fixture(CloudAccountSnapshot(phase: .signedIn, gate: Self.gate, displayName: "Sam Rivera",
                                             coverage: [.init(sourceId: "m", inventoryRow: "I01", complete: true, items: 3, bytes: 120_000, blockedReasons: [])],
                                             cloudHead: CloudSequence(4), fetched: CloudSequence(4)))
        account.fixtureUser(CloudUserIdentity(id: "u1", displayName: "Sam Rivera", provider: "github"))
        for dark in [false, true] {
            try render(SidePanelBottomFixture(), "side-panel-bottom", dark, output, size: CGSize(width: 264, height: 120))
            try render(NativeCloudSettings(), "settings-cloud", dark, output, size: CGSize(width: 680, height: 900))
        }
    }

    private func render<V: View>(_ view: V, _ name: String, _ dark: Bool, _ output: URL, size: CGSize) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height))
        host.sizingOptions = []
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("same-everywhere-\(name)-\(dark ? "dark" : "light").png"))
    }
}

/// The side panel's bottom bar as it is now: the divider, then his profile and the gear at 44 pt, and no Cloud line.
private struct SidePanelBottomFixture: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    SidebarProfileButton(enabled: true) {}
                    Spacer(minLength: 0)
                    Image(systemName: "gearshape").frame(width: 28, height: 28)
                }
                .foregroundStyle(.secondary)
                .frame(height: 44)
            }
            .padding(.horizontal, 12)
            .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DeckSidebarMaterial())
    }
}
