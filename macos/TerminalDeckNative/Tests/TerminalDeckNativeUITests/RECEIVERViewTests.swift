// Actual app views, offscreen proof only. Runs solely when RECEIVER_RENDER_TESTS=1.
// Runtime screenshots additionally require the shared foundation READY GLITCH receipt.
// Every product view uses fake model transport; no app launch or actual AI calls.
import AppKit
import CryptoKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

final class RECEIVERViewTests: XCTestCase {
    @MainActor
    private static var receipt: [String] = []
    @MainActor
    private static var runStarted = Date.distantPast
    @MainActor
    private static var fullFrames = 0
    @MainActor
    private static var output = URL(fileURLWithPath: "/Users/imatch/Projects/Personal/td-native-shell/macos/design-2026-10-10/built.noindex", isDirectory: true)

    @MainActor
    func testAllReceiverScreensRenderInLightAndDark() async throws {
        guard ProcessInfo.processInfo.environment["RECEIVER_RENDER_TESTS"] == "1" else {
            throw XCTSkip("WIP RECEIVER: explicit RECEIVER_RENDER_TESTS=1 enables offscreen proof")
        }
        let route = try String(contentsOfFile: "/Users/imatch/Projects/Personal/td-native-shell/macos/docker/ROUTE.md", encoding: .utf8)
        guard route.split(separator: "\n").contains(where: { $0.hasPrefix("READY GLITCH") || $0.hasPrefix("READY L1-CORE") }) else {
            throw Self.failure("READY GLITCH is required before final Receiver renders")
        }
        try Self.prepareOutput()
        Self.runStarted = Date(); Self.fullFrames = 0
        let referencesBefore = try Self.referenceSnapshot()
        Self.receipt = ["RUN \(UUID().uuidString) started=\(Self.runStarted.ISO8601Format())", "NO APP LAUNCH: XCTest + standalone NSHostingView only; no NSApplication, NSWindow, helper bundle, activation or production engine", "APPROVED v1: blue switches and selected type outline, vivid project dots and status colours; only agent tile backgrounds are neutral"] + referencesBefore
        try Self.writeReceipt()
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            for section in ["Flow", "Events", "Sources", "Rules"] {
                let model = try Self.fixture()
                model.place = section == "Sources" ? .sources : section == "Rules" ? .rules : .flow
                try await Self.render(NativeRCVScreen(model: model, section: section), dark: dark,
                    size: CGSize(width: 1440, height: 860), name: "RECEIVER-\(section.lowercased())-\(theme)")
                model.stop()
            }
            let model = try Self.fixture()
            model.projectFilter = "imatch"
            try await Self.render(NativeRCVAddSourceSheet(model: model, preset: RCVPresets.whapi, initialName: "iMatch WhatsApp"), dark: dark,
                size: CGSize(width: 640, height: 560), name: "RECEIVER-add-source-\(theme)")
            let external = model.sources.first(where: { $0.id == "wa" })!
            let created = try RCVPresentation.decode(RCVPresentation.Created.self, from: [
                "source": try RCVWire.value(external).foundation!,
                "reveal": try RCVWire.value(RCVSecretReveal(sourceId: external.id,
                    secret: "fixture-secret-only", addressWithSecret: "https://receiver.example.invalid/wa/fixture-secret-only")).foundation!
            ])
            try await Self.render(NativeRCVAddSourceSheet(model: model, preset: RCVPresets.whapi, created: created), dark: dark,
                size: CGSize(width: 640, height: 560), name: "RECEIVER-add-source-address-\(theme)")
            model.projectFilter = nil
            for source in [model.sources.first(where: { $0.id == "wa" })!, model.sources.first(where: { $0.id == "terminaldeck.tasks" })!] {
                for tab in ["General", "Events", "Rules", "Address", "Log"] {
                    try await Self.render(NativeRCVSourceSettingsView(model: model, view: source, initialTab: tab), dark: dark,
                        size: CGSize(width: 600, height: 520), name: "RECEIVER-settings-\(source.id)-\(tab.lowercased())-\(theme)")
                }
            }
            model.stop()
        }
        XCTAssertEqual(Self.fullFrames, 32)
        XCTAssertEqual(try Self.referenceSnapshot(), referencesBefore, "References changed during rendering; compare and rerender against the new files")
        Self.receipt.append("PASS 32 new whole frames +32 detail crops; references unchanged during run; visual comparison still requires inspection")
        try Self.writeReceipt()
    }


    @MainActor
    func testReceiverNavigationKeepsSameDetachedHostFrame() async throws {
        guard ProcessInfo.processInfo.environment["RECEIVER_RENDER_TESTS"] == "1" else {
            throw XCTSkip("WIP RECEIVER: explicit RECEIVER_RENDER_TESTS=1 enables offscreen navigation proof")
        }
        let route = try String(contentsOfFile: "/Users/imatch/Projects/Personal/td-native-shell/macos/docker/ROUTE.md", encoding: .utf8)
        guard route.split(separator: "\n").contains(where: { $0.hasPrefix("READY GLITCH") || $0.hasPrefix("READY L1-CORE") }) else {
            throw Self.failure("READY GLITCH is required before final Receiver renders")
        }
        try Self.prepareOutput()
        Self.runStarted = Date()
        let references = try Self.referenceSnapshot()
        var lines = ["RUN \(UUID().uuidString) started=\(Self.runStarted.ISO8601Format())", "NO APP LAUNCH: same detached NSHostingView; frame proof concerns the test host, not an app window"] + references
        let size = CGSize(width: 1440, height: 860)
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            let model = try Self.fixture()
            let host = NSHostingView(rootView: NativeRCVScreen(model: model, section: "Sources")
                .environment(\.colorScheme, dark ? .dark : .light).frame(width: size.width, height: size.height))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(origin: .zero, size: size)
            let frame = host.frame, bounds = host.bounds
            var firstPixels: CGSize?
            for phase in [("sources-first", "Sources"), ("events", "Events"), ("sources-return", "Sources")] {
                model.showSection(phase.1)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(250))
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                XCTAssertEqual(model.section, phase.1)
                XCTAssertEqual(host.frame, frame)
                XCTAssertEqual(host.bounds, bounds)
                XCTAssertNil(host.window, "A test host must never join an app window")
                let pixels = try Self.capture(host, rect: host.bounds, file: "RECEIVER-navigation-\(phase.0)-\(theme).png")
                if let firstPixels { XCTAssertEqual(pixels, firstPixels) } else { firstPixels = pixels }
                lines.append("PASS \(theme) \(phase.1) sameHost=true frame=\(host.frame) bounds=\(host.bounds) PNG=\(pixels) window=nil")
            }
            model.stop()
        }
        XCTAssertEqual(try Self.referenceSnapshot(), references, "References changed during same-host navigation proof")
        lines.append("PASS Sources → Events → Sources in both themes: six fresh frames with unchanged host/pixel bounds; no app-window proof claimed")
        try lines.joined(separator: "\n").write(to: Self.destination("RECEIVER-navigation-result.txt"), atomically: true, encoding: .utf8)
    }

    @MainActor
    static func fixture() throws -> NativeRCVModel {
        let now = Date().timeIntervalSince1970 * 1000
        let records: [(String, String, String, String?, Int, Bool, RCVOrigin)] = [
            ("wa", "iMatch WhatsApp", "whapi", "imatch", 23, true, .relay),
            ("errors", "iMatch errors", "sentry", "imatch", 12, true, .relay),
            ("repo", "CRM repository", "github", "crm", 4, true, .relay),
            ("crm", "CRM tasks", "crm", "crm", 0, false, .relay),
            ("uptime", "Site uptime", "uptime", "imatch", 2, true, .relay),
            ("webhook", "Any webhook", "generic", "independent", 0, true, .relay),
            ("terminaldeck.tasks", "Tasks", "terminaldeck", nil, 9, true, .terminalDeck),
            ("terminaldeck.sessions", "Sessions", "terminaldeck", nil, 31, true, .terminalDeck),
            ("terminaldeck.servers", "Servers", "terminaldeck", nil, 1, true, .terminalDeck),
            ("terminaldeck.containers", "Containers", "terminaldeck", nil, 6, true, .terminalDeck),
            ("terminaldeck.staysfixed", "Stays Fixed", "terminaldeck", nil, 0, false, .terminalDeck),
            ("terminaldeck.approvals", "Approvals", "terminaldeck", nil, 3, true, .terminalDeck)
        ]
        let sources = records.map { record in
            let source = RCVSource(id: record.0, name: record.1, preset: record.2, origin: record.6,
                auth: .init(scheme: record.6 == .terminalDeck ? .none : .token), mapping: .init(),
                enabled: record.5, createdAt: now - 86_400_000, projectID: record.3)
            return RCVSourceView(source: source,
                address: record.6 == .terminalDeck ? nil : "https://receiver.example.invalid/\(record.0)",
                active: record.5, hasReplyCredential: false, lastEventAt: record.4 == 0 ? nil : now - 60_000,
                eventCount: record.4, rejectedCount: 0)
        }
        let rules = [
            RCVRule(id: "rule-errors", name: "When iMatch errors sends an error → Release reviewer",
                sourceIds: ["errors"], conditions: [.init("kind", .equals, "error")],
                target: .init(kind: .agent, id: "reviewer")),
            RCVRule(id: "rule-wa", name: "When iMatch WhatsApp sends a message → Commander",
                sourceIds: ["wa"], conditions: [.init("kind", .equals, "message")],
                target: .init(kind: .session, id: "commander"))
        ]
        var events = [
            RCVEvent(id: "message-1", sourceId: "wa", receivedAt: now - 60_000, kind: "message", title: "Can you check the latest release?", text: "A test message"),
            RCVEvent(id: "error-1", sourceId: "errors", receivedAt: now - 120_000, kind: "error", title: "A page failed to load", text: "An example error"),
            RCVEvent(id: "repo-1", sourceId: "repo", receivedAt: now - 180_000, kind: "push", title: "Receiver source controls updated", text: "An example code change")
        ]
        events[0].status = .delivered
        for record in records {
            let existing = events.filter { $0.sourceId == record.0 }.count
            guard record.4 > existing else { continue }
            for index in existing..<record.4 {
                var event = RCVEvent(id: "\(record.0)-fixture-\(index)", sourceId: record.0,
                    receivedAt: now - Double(index * 1000), kind: "event", title: "Example event \(index + 1)", text: "Render fixture only")
                event.status = .delivered
                events.append(event)
            }
        }
        let overview = RCVOverview(sources: sources, rules: rules, events: events, unrouted: 2, held: 0,
            relayConnected: true, relayBase: "https://receiver.example.invalid", presets: RCVPresets.all,
            agents: [.init(id: "reviewer", name: "Release reviewer")], sessions: [.init(id: "commander", name: "Commander")])
        let answer = try RCVWire.value(overview).foundation!
        let model = NativeRCVModel(sourceEvents: [], read: { channel, _ in
            guard channel == "receiver:overview" else { throw failure("unrequested fixture channel: \(channel)") }
            return answer
        })
        model.overview = overview; model.loading = false
        return model
    }


    @MainActor
    func testSourceHandlersUseOnlyFakeTransport() async throws {
        guard ProcessInfo.processInfo.environment["RECEIVER_RENDER_TESTS"] == "1" else {
            throw XCTSkip("WIP RECEIVER: explicit RECEIVER_RENDER_TESTS=1 enables fixture checks")
        }
        let fixtureModel = try Self.fixture()
        let original = try XCTUnwrap(fixtureModel.sourceView("terminaldeck.tasks"))
        let originalEvents = try XCTUnwrap(fixtureModel.overview?.events)
        let fakeEvent = RCVEvent(id: "fixture-test", sourceId: original.id, receivedAt: 0, kind: "receiver.test", title: "Fixture only")
        var calls: [(String, [String: Any])] = []
        let model = NativeRCVModel(sourceEvents: [], read: { channel, args in
            let payload = args.first as? [String: Any] ?? [:]
            calls.append((channel, payload))
            switch channel {
            case "receiver:sourceSave":
                let source = try RCVPresentation.decode(RCVSource.self, from: try XCTUnwrap(payload["source"]))
                var view = original; view.source = source
                return try RCVWire.value(view).foundation!
            case "receiver:test":
                return [
                    "decision": try RCVWire.value(RCVDecision(status: .unrouted, reason: "Fixture dry run only")).foundation!,
                    "event": try RCVWire.value(fakeEvent).foundation!
                ]
            default:
                throw Self.failure("Unexpected channel: " + channel)
            }
        })
        model.overview = fixtureModel.overview; model.loading = false
        await model.setEnabled(original, false)
        XCTAssertEqual(model.sourceView(original.id)?.source.enabled, false)
        await model.testSource(original)
        XCTAssertEqual(calls.map { $0.0 }, ["receiver:sourceSave", "receiver:test"])
        XCTAssertEqual(calls.last?.1["sourceId"] as? String, original.id)
        XCTAssertTrue((calls.last?.1["sample"] as? String)?.contains("Receiver test event") == true)
        XCTAssertEqual(model.overview?.events, originalEvents)
        XCTAssertNil(model.busy)
        XCTAssertNil(model.actionError)
        model.stop(); fixtureModel.stop()
    }

    @MainActor
    private static func prepareOutput() throws {
        let root = URL(fileURLWithPath: "/Users/imatch/Projects/Personal/td-native-shell", isDirectory: true).resolvingSymlinksInPath()
        func verify(_ url: URL) throws {
            guard url.path.hasPrefix(root.path + "/"), url.lastPathComponent == "built.noindex",
                  url.pathComponents.contains(where: { $0.hasSuffix(".noindex") }) else {
                throw failure("Canonical render output must stay inside the workspace built.noindex folder")
            }
        }
        try verify(output.resolvingSymlinksInPath())
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        output = output.resolvingSymlinksInPath()
        try verify(output)
    }

    @MainActor
    private static func render<V: View>(_ view: V, dark: Bool, size: CGSize, name: String) async throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        XCTAssertNil(host.window, "Snapshot host must never join a window")
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        XCTAssertEqual(host.frame.size, size)
        XCTAssertNil(host.window)
        let pixels = try capture(host, rect: host.bounds, file: name + ".png")
        let crop = NSRect(x: 20, y: max(0, size.height - 360), width: min(size.width - 40, 640), height: min(340, size.height))
        _ = try capture(host, rect: crop, file: name + "-detail.png")
        receipt.append("PASS \(name) hostFrame=\(host.frame) PNG=\(pixels.width)x\(pixels.height) window=nil")
        try writeReceipt()
    }
    @MainActor
    private static func capture(_ host: NSView, rect: NSRect, file: String) throws -> CGSize {
        guard file.hasPrefix("RECEIVER-"), !file.contains("/"),
              output.resolvingSymlinksInPath().lastPathComponent == "built.noindex" else {
            throw failure("Unsafe output path")
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: rect) else { throw failure("Bitmap missing") }
        host.cacheDisplay(in: rect, to: bitmap)
        guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { throw failure("Empty bitmap") }
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw failure("PNG missing") }
        let url = try destination(file)
        try bytes.write(to: url, options: .atomic)
        let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        guard let modified, modified >= runStarted.addingTimeInterval(-1) else { throw failure("PNG was not written in this run") }
        if !file.hasSuffix("-detail.png") { fullFrames += 1 }
        return CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
    }
    @MainActor
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "ReceiverViewTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    @MainActor
    private static func destination(_ file: String) throws -> URL {
        guard file.hasPrefix("RECEIVER-"), !file.contains("/"), !file.contains("..") else { throw failure("Unsafe filename") }
        let url = output.appendingPathComponent(file).resolvingSymlinksInPath()
        guard url.deletingLastPathComponent() == output, url.lastPathComponent == file,
              url.pathComponents.contains(where: { $0.hasSuffix(".noindex") }) else { throw failure("Output symlink escapes built.noindex") }
        return url
    }
    @MainActor
    private static func referenceSnapshot() throws -> [String] {
        let design = URL(fileURLWithPath: "/Users/imatch/Projects/Personal/td-native-shell/macos/design-2026-10-10", isDirectory: true)
        return try ["DESIGN-SYSTEM.md", "mockups.noindex/07-receiver-light.png", "mockups.noindex/07-receiver-dark.png", "mockups.noindex/07b-receiver-add-source-light.png"].map { relative in
            let url = design.appendingPathComponent(relative).resolvingSymlinksInPath()
            guard url.path.hasPrefix(design.resolvingSymlinksInPath().path + "/") else { throw failure("Reference symlink escapes design folder") }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let modified = (attributes[.modificationDate] as? Date)?.ISO8601Format() ?? "unknown"
            let bytes = try Data(contentsOf: url)
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            return "REFERENCE \(relative) modified=\(modified) bytes=\(bytes.count) sha256=\(hash)"
        }
    }
    @MainActor
    private static func writeReceipt() throws {
        try receipt.joined(separator: "\n").write(to: destination("RECEIVER-render-result.txt"), atomically: true, encoding: .utf8)
    }
}
