import AppKit
import SwiftUI
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// "Switch to this Mac": the page's one line in each state he can meet, light and dark, drawn offscreen into
/// night/codex/switch-mac-evidence (never in a window). Also checks that the button is there only where it belongs.
@MainActor
final class CloudSwitchMacLinePictures: XCTestCase {
    static func row(on: Bool = true, closed: Bool = false, kind: String = "chat") -> BackendCloudSessionsRead.Row {
        .init(ref: "0123456789abcdef0123456789abcdef", name: "Site redesign", lastUsedAt: 1_794_700_000_000, project: nil, ai: "claude",
              kind: kind, status: "idle", machineName: "MacBook Air", machineOn: on, mine: false, closedAt: closed ? 1_794_700_000_000 : nil)
    }

    func testButtonOnlyOnAnotherMacsOpenSession() {
        func canSwitch(_ state: NativeCloudMoveLine.State) -> Bool {
            switch state {
            case .plain(_, let can), .said(_, let can): return can
            case .moving: return false
            }
        }
        XCTAssertTrue(canSwitch(NativeCloudMoveLine.state(row: Self.row(), machine: "MacBook Air", move: nil)))
        XCTAssertTrue(canSwitch(NativeCloudMoveLine.state(row: Self.row(on: false), machine: "MacBook Air", move: nil)))
        XCTAssertFalse(canSwitch(NativeCloudMoveLine.state(row: Self.row(closed: true), machine: "MacBook Air", move: nil)), "an Earlier chat runs nowhere")
        XCTAssertFalse(canSwitch(NativeCloudMoveLine.state(row: Self.row(kind: "hoot"), machine: "MacBook Air", move: nil)), "never on Hoot's chat")
        XCTAssertEqual(NativeCloudMoveLine.state(row: Self.row(), machine: "MacBook Air", move: ("Moving from MacBook Air…", true, true)),
                       .moving("Moving from MacBook Air…"))
    }

    func testPicturesEveryLineBothThemes() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = package.deletingLastPathComponent().appendingPathComponent("night/codex/switch-mac-evidence")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let states: [(String, NativeCloudMoveLine.State)] = [
            ("1-runs-on", .plain("Runs on MacBook Air", canSwitch: true)),
            ("2-runs-on-off", .plain("Runs on MacBook Air, which is off", canSwitch: true)),
            ("3-moving", .moving("Moving from MacBook Air…")),
            ("4-replying", .moving("MacBook Air is finishing its reply; it moves when the reply is done.")),
            ("5-moved", .said("Moved from MacBook Air. Its code was backed up first.", canSwitch: false)),
            ("6-off", .said("MacBook Air is off. The chat is from 14:32 and the code here is from 14:10 (its last backup).", canSwitch: false)),
            ("7-never-backed-up", .said("MacBook Air is off. The chat is from 14:32. The code here is this Mac's own; MacBook Air never backed this project up.", canSwitch: false)),
            ("8-terminal", .said("Moved. A new terminal opened here in the same folder; programs that were running on MacBook Air did not move.", canSwitch: false)),
            ("9-sign-in", .said("Sign in to Claude on this Mac to move this chat.", canSwitch: true)),
            ("10-no-github", .said("Moved. Connect GitHub to bring its code.", canSwitch: false)),
            ("11-moved-away", .said("This session moved to Mac mini at 14:40. What was done here after that is kept: the code in Code backup, the chat in Earlier chats.", canSwitch: true)),
        ]
        for (name, state) in states {
            let page = VStack(alignment: .leading, spacing: 3) {
                Text("Site redesign").font(.title3.weight(.semibold)).lineLimit(1)
                NativeCloudMoveLine(state: state)
            }
            .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            for dark in [false, true] { try render(page, "switch-mac-\(name)", dark, output) }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("switch-mac-1-runs-on-dark.png").path))
    }

    private func render<V: View>(_ view: V, _ name: String, _ dark: Bool, _ output: URL, size: CGSize = CGSize(width: 760, height: 120)) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height).background(DeckTokens.frame))
        host.sizingOptions = []
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }
}
