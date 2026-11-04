import AppKit
import SwiftUI
import XCTest
@testable import TerminalDeckNative

@MainActor
final class OneIdentityRenderTests: XCTestCase {
    func testPrivacySettingsAndCleanupInBothThemesWithoutWindows() throws {
        XCTAssertNotNil(NativeSettingsNavigation.item("privacy"))
        XCTAssertNotNil(NativeScreens.settings(sectionId: "privacy"))
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let lanePath = try? String(contentsOf: repo.appendingPathComponent(".lane-root"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let lane = lanePath.map { URL(fileURLWithPath: $0) } ?? repo
        let output = lane.appendingPathComponent("macos/TerminalDeckNative/.build/one-identity-renders.noindex")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for dark in [false, true] {
            let page = NativeSettingsShell(selection: .constant("privacy")) { _ in NativePrivacySettings(showCleanup: true) }
            try capture(page, size: .init(width: 900, height: 800), dark: dark, output: output.appendingPathComponent("privacy-\(dark ? "dark" : "light").png"))
            try capture(NativePrivacyCleanupSteps().padding(20).background(DeckTokens.page), size: .init(width: 620, height: 340), dark: dark,
                        output: output.appendingPathComponent("cleanup-\(dark ? "dark" : "light").png"))
        }
    }
    private func capture<V: View>(_ view: V, size: CGSize, dark: Bool, output: URL) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light).frame(width: size.width, height: size.height))
        host.sizingOptions = []; host.frame = NSRect(origin: .zero, size: size)
        let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua)); host.appearance = appearance
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(host.window)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output)
        print("OneIdentity render: \(output.path)")
    }
}
