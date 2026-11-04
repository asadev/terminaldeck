import AppKit
import SwiftUI
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class AgentStartRecoveryViewTests: XCTestCase {
    func testRecoveryControlsInBothThemesAndWhilePending() throws {
        for dark in [false, true] {
            for pending in [false, true] {
                let view = VStack(alignment: .leading, spacing: 12) {
                    Text("Team conversations · 1").font(.headline)
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right")
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Commander → Codex · Saved work").font(.callout)
                            Text("Ended by restart").font(.caption).foregroundStyle(.secondary)
                            Text("The saved AI conversation is ready to resume.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open") {}.controlSize(.small)
                        AGTTeamChatRecoveryControl(pending: pending, resume: {})
                    }
                    Spacer()
                }.padding(20).frame(width: 760, height: 180)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: view)
                host.sizingOptions = []
                host.frame = NSRect(x: 0, y: 0, width: 760, height: 180)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                var output = URL(fileURLWithPath: #filePath)
                for _ in 0..<4 { output.deleteLastPathComponent() }
                output.appendPathComponent("design-2026-10-10/built.noindex/agent-start-gaps")
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try png.write(to: output.appendingPathComponent("recovery-\(dark ? "dark" : "light")-\(pending ? "pending" : "ready").png"))
            }
        }
    }
    func testCompactConversationExposesRestartAndResumeWithoutPrivateInput() throws {
        var input = BackendCreateSessionInput(cwd: "/scratch", provider: "codex")
        input.chat = true
        let meta = BackendSessionMeta(id: "restarted", input: input,
            spawn: .init(provider: "codex", command: "/never-run", args: [], path: "/usr/bin"))
        var row = BackendTeamChatRecord(session: meta,
            job: .init(fromID: "lead", fromName: "Lead", agentID: "codex", agentName: "Codex", title: "Saved work"), key: "restarted")
        row.interruptedAt = Date()
        row.finishedAt = Date()
        row.resumeInput = input
        let compact = NativeTeamChatListPage.compact(row)
        XCTAssertEqual(compact["state"], .string("ended-by-restart"))
        XCTAssertEqual(compact["resume"]["do"], .string("resume"))
        XCTAssertEqual(compact["resume"]["sessionId"], .string("restarted"))
        XCTAssertFalse(compact.has("resumeInput"))
        row.resumedBySessionID = "new-session"
        XCTAssertTrue(NativeTeamChatListPage.compact(row)["resume"].isNullish)
    }
}
