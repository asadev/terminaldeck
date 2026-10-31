import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Shared native UI XCTest target. No app, window, AppModel, engine, account, or AI starts.
@objc(ORGRenderTests)
final class ORGRenderTests: XCTestCase {
    @MainActor @objc func testLight1440() throws { try requireORGFocused(); try capture(dark: false, size: CGSize(width: 1440, height: 900)) }
    @MainActor @objc func testDark1440() throws { try requireORGFocused(); try capture(dark: true, size: CGSize(width: 1440, height: 900)) }
    @MainActor @objc func testLight1000() throws { try requireORGFocused(); try capture(dark: false, size: CGSize(width: 1000, height: 700)) }
    @MainActor @objc func testDark1000() throws { try requireORGFocused(); try capture(dark: true, size: CGSize(width: 1000, height: 700)) }

    func requireORGFocused() throws {
        guard ProcessInfo.processInfo.environment["ORG_FOCUSED_UI"] == "1" else { throw XCTSkip("WIP ORG") }
    }

    @MainActor func testManagerHootAndIndependentSaveThroughTheRealHandler() async throws {
        try requireORGFocused()
        for manager in [Optional("b"), Optional("@hoot"), nil] {
            var calls: [(String, String?)] = []
            let model = dropModel(managers: ["a": nil, "b": nil, "c": "b"], save: { id, boss in
                calls.append((id, boss)); return true
            })
            XCTAssertTrue(model.accept(id: "a", manager: manager))
            XCTAssertEqual(model.busyID, "a")
            let saved = await model.waitForSave()
            XCTAssertTrue(saved)
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(calls.first?.0, "a")
            XCTAssertEqual(calls.first?.1, manager)
            XCTAssertNil(model.busyID)
            XCTAssertNil(model.message)
        }
    }

    @MainActor func testRefusedManagerChangesNeverCallSave() async throws {
        try requireORGFocused()
        var calls = 0
        let model = dropModel(managers: ["a": nil, "b": "a", "c": "b"], save: { _, _ in
            calls += 1; return true
        })
        for (id, boss) in [("a", "a"), ("a", "c"), ("session:probe", "@hoot"),
                           ("unknown", "@hoot"), ("a", "unknown")] {
            XCTAssertFalse(model.accept(id: id, manager: boss))
            XCTAssertNil(model.busyID)
            XCTAssertNotNil(model.message)
        }
        XCTAssertEqual(calls, 0)
        let saved = await model.waitForSave()
        XCTAssertFalse(saved)
    }

    @MainActor func testPendingManagerSaveRejectsTheSecondDrop() async throws {
        try requireORGFocused()
        var calls = 0
        let model = dropModel(managers: ["a": nil, "b": nil, "c": nil], save: { _, _ in
            calls += 1; return true
        })
        XCTAssertTrue(model.accept(id: "a", manager: "@hoot"))
        XCTAssertFalse(model.accept(id: "b", manager: nil))
        XCTAssertEqual(model.busyID, "a")
        let saved = await model.waitForSave()
        XCTAssertTrue(saved)
        XCTAssertEqual(calls, 1)
        XCTAssertNil(model.busyID)
    }

    @MainActor func testFailedManagerSaveClearsPendingAndShowsTheFailure() async throws {
        try requireORGFocused()
        var published: [String?] = []
        let model = dropModel(managers: ["a": nil, "b": nil, "c": nil], save: { _, _ in false },
                              failure: { "Fixture save refusal" }, publish: { published.append($0) })
        XCTAssertTrue(model.accept(id: "a", manager: "@hoot"))
        let saved = await model.waitForSave()
        XCTAssertFalse(saved)
        XCTAssertNil(model.busyID)
        XCTAssertEqual(model.message, "Fixture save refusal")
        XCTAssertEqual(published.last ?? nil, "Fixture save refusal")
    }

    @MainActor func dropModel(managers: [String: String?], save: @escaping (String, String?) async -> Bool,
                             failure: @escaping () -> String? = { nil },
                             publish: @escaping (String?) -> Void = { _ in }) -> ORGManagerDropModel {
        ORGManagerDropModel(kind: { id in
            if id == "@hoot" { return .hoot }
            if id == "session:probe" { return .session }
            return ["a", "b", "c"].contains(id) ? .profile : nil
        }, managers: { managers }, names: { ["a": "a", "b": "b", "c": "c"] },
        save: save, failure: failure, publish: publish)
    }

    @MainActor func capture(dark: Bool, size: CGSize) throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORG_RENDER_OUTPUT"] ??
            "/Users/imatch/Projects/Personal/td-native-shell/macos/design-2026-10-10/built.noindex", isDirectory: true)
        guard output.lastPathComponent.hasSuffix(".noindex") else {
            throw failure("ORG renders require a .noindex folder.")
        }
        let store = AGTAgentsStore.shared
        store.fixture = TasksState(agents: Self.fixture)
        store.live = Self.liveFixture
        store.liveLoaded = true
        store.openProfile = nil
        store.search = ""
        store.message = nil
        NativePROJLabels.shared.projects = PROJProjects.defaults
        let name = "ORG-org-\(dark ? "dark" : "light")-\(Int(size.width))x\(Int(size.height))"
        try render(AGTAgentsScreen(mode: .org, live: false), size: size, dark: dark,
                   to: output.appendingPathComponent(name + ".png"))
    }

    static var fixture: [AgentProfile] {
        let rows: [(String, String?, String, String)] = [
            ("analyst", "@hoot", "imatch", "chart.bar"),
            ("accounts-keeper", "analyst", "imatch", "person.badge.key"),
            ("matchmaker", "analyst", "imatch", "star"),
            ("db-surgeon", "analyst", "imatch", "cylinder.split.1x2"),
            ("ios-engineer", "@hoot", "imatch", "iphone"),
            ("android-engineer", "ios-engineer", "imatch", "apps.iphone"),
            ("portal-mechanic", "@hoot", "crm", "wrench"),
            ("crm-db", "portal-mechanic", "crm", "cylinder.split.1x2"),
            ("diff-verifier", "portal-mechanic", "crm", "checkmark.shield"),
            ("whatsapp-officer", "accounts-keeper", "imatch", "message"),
            ("critic", nil, "independent", "ladybug"),
        ]
        let independent = ["scribe", "ops-watcher", "inspector", "n8n-mechanic", "design-keeper",
                           "docs-keeper", "planner", "researcher", "server-keeper", "reviewer", "support-agent"]
        let miniIcons = ["scribe": "pencil", "ops-watcher": "eye", "inspector": "magnifyingglass",
                         "n8n-mechanic": "wrench", "design-keeper": "paintpalette"]
        return rows.map { id, manager, project, icon in
            AgentProfile(id: id, name: id, provider: "claude", status: id == "critic" ? .paused : .active,
                         icon: "sf:\(icon)", reportsTo: manager, projectID: project)
        } + independent.map {
            AgentProfile(id: $0, name: $0, provider: "claude", status: .active,
                         icon: "sf:\(miniIcons[$0] ?? "person.crop.circle")", projectID: "independent")
        }
    }

    static var liveFixture: [AWWatchAgent] {
        let rows = [("@hoot", "Hoot", "hoot", "working", "independent"),
                    ("accounts-keeper", "accounts-keeper", "task", "working", "imatch"),
                    ("db-surgeon", "db-surgeon", "task", "working", "imatch"),
                    ("ios-engineer", "ios-engineer", "task", "waiting", "imatch"),
                    ("portal-mechanic", "portal-mechanic", "task", "working", "crm")]
        return rows.compactMap { id, name, kind, state, project in
            AWWatchAgent.decode(.object([
                .init("id", .string("fixture-live:\(id)")), .init("sourceID", .string(id)),
                .init("kind", .string(kind)), .init("name", .string(name)),
                .init("state", .string(state)), .init("taskID", .string("fixture-task:\(id)")),
                .init("projectId", .string(project)), .init("machineName", .string("This Mac")),
                .init("provider", .string("claude")), .init("action", .string(state == "working" ? "Working" : "Waiting for you")),
            ]))
        }
    }

    @MainActor func render<V: View>(_ view: V, size: CGSize, dark: Bool, to url: URL) throws {
        guard let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) else {
            throw failure("Could not resolve the native drawing appearance.")
        }
        var captureError: Error?
        appearance.performAsCurrentDrawingAppearance {
            do { try draw(view, size: size, dark: dark, appearance: appearance, to: url) }
            catch { captureError = error }
        }
        if let captureError { throw captureError }
    }

    @MainActor func draw<V: View>(_ view: V, size: CGSize, dark: Bool, appearance: NSAppearance, to url: URL) throws {
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light)))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = appearance
        guard host.window?.isVisible != true && NSApp?.isActive != true else {
            throw failure("Hidden render must stay invisible and inactive before capture.")
        }
        // Standalone fixed-frame view. No window or app is created, ordered, or activated.
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw failure("Could not allocate the hidden render bitmap.")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard host.window?.isVisible != true && NSApp?.isActive != true else {
            throw failure("Hidden render became visible or active during capture.")
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw failure("Could not encode the hidden render.")
        }
        try png.write(to: url)
        print("\(url.lastPathComponent) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh) visible=false active=false")
        guard let image = bitmap.cgImage else { throw failure("Could not read the native crop image.") }
        let scaleX = CGFloat(image.width) / size.width
        let scaleY = CGFloat(image.height) / size.height
        let areas: [(String, CGRect)] = [
            ("tree-detail", CGRect(x: 16, y: 80, width: size.width - 32, height: size.height - 200)),
            ("controls-detail", CGRect(x: 8, y: size.height - 104, width: size.width - 16, height: 96)),
        ]
        for (detail, area) in areas {
            let pixels = CGRect(x: area.minX * scaleX, y: area.minY * scaleY,
                                width: area.width * scaleX, height: area.height * scaleY).integral
            guard let crop = image.cropping(to: pixels),
                  let data = NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]) else {
                throw failure("Could not encode \(detail) from the native bitmap.")
            }
            let cropURL = url.deletingPathExtension().appendingPathExtension("\(detail).png")
            try data.write(to: cropURL)
            print("\(cropURL.lastPathComponent) native bitmap crop \(crop.width)x\(crop.height)")
        }
    }

    func failure(_ message: String) -> NSError {
        NSError(domain: "ORGRender", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
