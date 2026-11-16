import AppKit
import SwiftUI
import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Sessions in the Cloud, step 1 (owner, 15 Nov: every session of his account on every device, "each carries ONE small
/// tag with the name of the machine it runs on"; "don't make it too busy"): his other machines' sessions sit with the
/// same project's sessions in the side panel (no tag and, since 15 Nov, no machine line: type icon and name only); "Earlier chats" is one
/// quiet row at the end of a project's sessions. Opening one shows its chat read only with one line on top.
/// Pictures in light and dark, drawn offscreen (never in a window), into `night/codex/sessions-cloud-evidence/`.
@MainActor
final class SidebarMachineTagTests: XCTestCase {
    private var package: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func source(_ name: String) throws -> String {
        try String(contentsOf: package.appendingPathComponent("Sources/TerminalDeckNative/" + name), encoding: .utf8)
    }
    typealias Row = BackendCloudSessionsRead.Row
    static func other(_ ref: String, _ name: String, project: String?, machine: String = "MacBook Air", on: Bool = true, at: Double = 2_000, ai: String = "claude") -> Row {
        Row(ref: ref, name: name, lastUsedAt: at, project: project.map { .init(cloudRef: $0, name: $0.uppercased()) }, ai: ai,
            kind: "terminal", status: "idle", machineName: machine, machineOn: on)
    }

    func testAnotherMachinesSessionSitsInItsProjectGroupWithItsTag() {
        let own: [(id: String, project: String?)] = [(id: "a", project: "crm"), (id: "b", project: nil), (id: "c", project: "crm")]
        let others = [Self.other("x", "Invoices", project: "crm"), Self.other("y", "Site copy", project: "web", at: 1_000)]
        let entries = SIDEBARCloudRows.merge(own: own, others: others, earlier: ["crm"])
        XCTAssertEqual(entries.map(\.id), ["a", "b", "c", "cloud-session:x", "cloud-earlier:crm", "cloud-session:y"])
        // His own rows keep exactly their order and are his own (no tag); the others are the Cloud's rows (one tag each).
        XCTAssertEqual(entries.compactMap { entry -> String? in if case .own(let id) = entry { return id }; return nil }, ["a", "b", "c"])
        XCTAssertEqual(entries.compactMap { entry -> String? in if case .other(let row) = entry { return row.machineName }; return nil }, ["MacBook Air", "MacBook Air"])
    }

    func testNoOtherMachineNoEarlierChatsNothingChanges() {
        let own: [(id: String, project: String?)] = [(id: "a", project: "crm"), (id: "b", project: nil)]
        XCTAssertEqual(SIDEBARCloudRows.merge(own: own, others: [], earlier: []).map(\.id), ["a", "b"])
        // Earlier chats of a project with no session listed: one quiet row ends the list.
        XCTAssertEqual(SIDEBARCloudRows.merge(own: own, others: [], earlier: ["old"]).map(\.id), ["a", "b", "cloud-earlier:"])
    }

    func testOwnRowsHaveNoTagAndTheOpenedChatSaysWhereItRuns() throws {
        let sidebar = try source("SidebarView.swift")
        // Small fixes item 5: no machine tag on any row. 15 Nov (DESIGN-SESSION-ROWS): no machine line either; another
        // machine's session is its type icon and its name, and "Runs on <machine>" is on its page.
        XCTAssertFalse(sidebar.contains("SIDEBARMachineTag"), "no row carries a machine tag")
        XCTAssertFalse(try source("NativeCloudChatsViews.swift").contains("SIDEBARMachineTag"), "a Cloud row carries no tag either")
        let cloudRow = SIDEBARCloudSessionRow(row: Self.other("x", "Invoices", project: "crm", machine: "Mac mini"), project: nil,
                                              highlighted: false, onAccent: false, selection: AnyView(Color.clear), open: {})
        XCTAssertEqual(cloudRow.title, "Invoices")
        XCTAssertFalse(cloudRow.chat, "a terminal session: the terminal icon")
        XCTAssertEqual(cloudRow.machine, "Mac mini", "kept for its page, not drawn on the row")
        XCTAssertFalse(try source("NativeCloudChatsViews.swift").contains("SIDEBARSessionLine.machineLine("), "no machine line on the row")
        XCTAssertEqual(SIDEBARSessionLine.machineLine(ai: "Codex", machine: "MacBook Air"), "Codex · MacBook Air")
        XCTAssertEqual(SIDEBARSessionLine.machineLine(ai: nil, machine: "MacBook Air"), "MacBook Air")
        XCTAssertEqual(SIDEBARSessionLine.machineName("machine m1 s1", names: ["m1": "Mac mini"]), "Mac mini")
        XCTAssertEqual(SIDEBARSessionLine.machineName("machine m1 s1", names: [:]), "Another Mac")
        XCTAssertNil(SIDEBARSessionLine.machineName(UUID().uuidString, names: [:]), "this Mac's own row keeps its line")
        XCTAssertNil(SIDEBARSessionLine.machineName("server s1 k1", names: [:]))
        XCTAssertEqual(NativeCloudChats.runsOn("MacBook Air", on: true), "Runs on MacBook Air")
        XCTAssertEqual(NativeCloudChats.runsOn("MacBook Air", on: false), "Runs on MacBook Air, which is off")
        XCTAssertTrue(SHELLRoutes.owns("cloud-session:abc") && SHELLRoutes.owns("cloud-earlier:crm"))
        // The sync choice: ONE question, yes by default.
        XCTAssertTrue(NativeCloudChats.sessionsAndChatsInSync())
    }

    // MARK: Pictures

    func testPicturesLightAndDark() throws {
        let output = package.deletingLastPathComponent().appendingPathComponent("night/codex/sessions-cloud-evidence")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let crm = PROJProject(id: "crm", name: "CRM", folders: ["/tmp/crm"])
        let reader = NativeCloudChatReader()
        func event(_ sequence: Int, _ kind: HootChatKind, _ text: String) -> HootChatEvent {
            HootChatEvent(conversationID: "c", turnID: "", sequence: sequence, provider: .claude, record: .text(kind, id: "m\(sequence)", text), at: 0)
        }
        reader.apply(newest: .init(gen: 1, total: 3, first: 0, count: 3, events: [
            event(1, .user, "Why does the invoice total round down?"),
            event(2, .message, "The total is rounded **before** tax is added. I moved the rounding to the end, so `12.345` now shows as 12.35."),
            event(3, .user, "Good, ship it."),
        ]))
        for dark in [false, true] {
            try render(PanelFixture(crm: crm), "side-panel", dark, output, size: CGSize(width: 264, height: 260))
            for on in [true, false] {
                try render(ChatFixture(reader: reader, on: on), on ? "chat-machine-on" : "chat-machine-off", dark, output, size: CGSize(width: 560, height: 320))
            }
        }
    }

    private func render<V: View>(_ view: V, _ name: String, _ dark: Bool, _ output: URL, size: CGSize) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light).frame(width: size.width, height: size.height))
        host.sizingOptions = []
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("sessions-cloud-\(name)-\(dark ? "dark" : "light").png"))
    }
}

/// The Running list as the panel draws it (15 Nov, DESIGN-SESSION-ROWS): two of this Mac's own sessions, one of the
/// MacBook Air's in the same project, one of the Mac mini's while that Mac is off, and "Earlier chats". Every session row
/// is its type icon and its name only.
private struct PanelFixture: View {
    let crm: PROJProject
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Running").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .frame(height: 28).padding(.horizontal, 8)
            OwnRow(title: "CRM", chat: true)
            OwnRow(title: "Login fix", chat: false)
            SIDEBARCloudSessionRow(row: SidebarMachineTagTests.other("x", "Invoices", project: "crm"), project: crm,
                                   highlighted: false, onAccent: false, selection: AnyView(Color.clear), open: {})
            SIDEBARCloudSessionRow(row: SidebarMachineTagTests.other("z", "Backups", project: "crm", machine: "Mac mini", on: false, ai: "codex"), project: crm,
                                   highlighted: false, onAccent: false, selection: AnyView(Color.clear), open: {})
            SIDEBAREarlierChatsRow(onAccent: false, selection: AnyView(Color.clear), open: {})
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.top, 8)
        .font(.system(size: 13))
        .background(DeckTokens.frame)
    }
}

/// This Mac's own row as SIDEBARSessionRow draws it (type icon, name), with no tag.
private struct OwnRow: View {
    let title: String
    let chat: Bool
    var body: some View {
        HStack(spacing: 8) {
            SIDEBARSessionTypeIcon(chat: chat)
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: DeckSidebar.rowHeight, alignment: .leading)
    }
}

/// Another machine's session opened: its name, the one line, its chat read from the Cloud (no send box).
private struct ChatFixture: View {
    let reader: NativeCloudChatReader
    let on: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Invoices").font(.title3.weight(.semibold))
                Text(NativeCloudChats.runsOn("MacBook Air", on: on)).font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 12)
            NativeCloudChatMessages(reader: reader, ref: "x")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DeckTokens.frame)
    }
}
