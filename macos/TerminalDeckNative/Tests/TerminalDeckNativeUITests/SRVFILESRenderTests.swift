import AppKit
import SwiftUI
import TerminalDeckNativeCore
import XCTest
@testable import TerminalDeckNative

/// SRVFILES #120: the server page's Files view and galleries, fixtures only (no server, no engine).
/// Pictures come from one borderless window ordered below every other window, never activated,
/// captured with `screencapture -l`, then closed.
@MainActor
final class SRVFILESRenderTests: XCTestCase {
    static let day: TimeInterval = 86_400
    static let now = Date(timeIntervalSince1970: 1_791_000_000)

    static func row(_ name: String, _ folder: String, _ kind: String = "file", _ size: Int64? = nil, ago: Double = 1, group: String? = nil, measure: Double? = nil) -> NativeServerFileRow {
        let type = kind == "folder" ? "folder" : BackendTypeHint.type(name)
        return NativeServerFileRow(name: name, path: folder + "/" + name, kind: kind, type: type, size: size,
                                   modified: now.addingTimeInterval(-ago * day), group: group, measure: measure)
    }
    enum BackendTypeHint {
        static func type(_ name: String) -> String {
            let e = (name as NSString).pathExtension.lowercased()
            if ["jpg", "jpeg", "png", "heic", "webp"].contains(e) { return "photo" }
            if ["mp4", "mov", "webm"].contains(e) { return "video" }
            if ["mp3", "m4a", "wav", "flac"].contains(e) { return "audio" }
            if ["pdf", "docx", "xlsx", "pptx"].contains(e) { return "document" }
            if ["md", "txt", "log", "csv"].contains(e) { return "text" }
            if ["sh", "json", "yml", "ts", "js"].contains(e) { return "code" }
            if ["gz", "zip", "tar"].contains(e) { return "archive" }
            return "other"
        }
    }
    static let home = "/home/deploy"
    static var folderRows: [NativeServerFileRow] {
        [row("apps", home, "folder", ago: 2), row("backups", home, "folder", ago: 1), row("media", home, "folder", ago: 6), row("uploads", home, "folder", ago: 0.2),
         row("README.md", home, "file", 4_812, ago: 12), row("deploy.sh", home, "file", 1_204, ago: 3), row("docker-compose.yml", home, "file", 2_390, ago: 8),
         row("backup-2026-10-09.tar.gz", home, "file", 2_576_980_378, ago: 1), row("invoice-september.pdf", home, "file", 184_320, ago: 20),
         row("launch-teaser.mp4", home + "/media", "file", 48_234_496, ago: 6), row("server.log", home, "file", 12_582_912, ago: 0.05)]
    }
    static let readme = """
    # iMatch production

    Apps on this server run from ~/apps with Docker Compose.

    - api      port 8080
    - web      port 3000
    - worker   no port

    Deploys: ./deploy.sh <app>   (pulls, builds, restarts one app)
    Backups: every night at 02:00 into ~/backups, kept 14 days.
    """
    static func picture(_ index: Int) -> NSImage {
        let size = NSSize(width: 360, height: 360)
        let image = NSImage(size: size)
        image.lockFocus()
        let hues: [(CGFloat, CGFloat)] = [(0.08, 0.55), (0.55, 0.62), (0.33, 0.45), (0.92, 0.05), (0.62, 0.75), (0.12, 0.18), (0.48, 0.58), (0.75, 0.85)]
        let pair = hues[index % hues.count]
        NSGradient(starting: NSColor(hue: pair.0, saturation: 0.55, brightness: 0.95, alpha: 1), ending: NSColor(hue: pair.1, saturation: 0.65, brightness: 0.55, alpha: 1))?
            .draw(in: NSRect(origin: .zero, size: size), angle: CGFloat(30 + index * 25))
        NSColor(white: 1, alpha: 0.35).setFill()
        NSBezierPath(ovalIn: NSRect(x: 40 + index * 17 % 120, y: 180, width: 120, height: 120)).fill()
        NSColor(white: 0, alpha: 0.18).setFill()
        let hill = NSBezierPath(); hill.move(to: .zero); hill.curve(to: NSPoint(x: 360, y: 0), controlPoint1: NSPoint(x: 120, y: 200 + index * 7 % 60), controlPoint2: NSPoint(x: 240, y: 60))
        hill.close(); hill.fill()
        image.unlockFocus()
        return image
    }
    static var photos: [NativeServerFileRow] {
        let names = ["beach-sunrise.jpg", "team-offsite.jpg", "office-plant.heic", "product-shot-01.png", "product-shot-02.png", "dubai-marina.jpg",
                     "logo-dark.png", "event-stage.jpg", "screenshot-dashboard.png", "night-skyline.jpg", "coffee.jpg", "whiteboard.jpg"]
        return names.enumerated().map { i, name in
            row(name, home + (i < 6 ? "/uploads/2026-10" : "/uploads/2026-09"), "file", Int64(380_000 + i * 913_337), ago: Double(i) * 4 + 1, group: i < 6 ? "2026-10" : "2026-09")
        }
    }
    static var videos: [NativeServerFileRow] {
        ["launch-teaser.mp4", "onboarding-walkthrough.mov", "support-call-recording.mp4", "drone-site-visit.mov", "app-demo-ios.mp4"].enumerated().map { i, name in
            row(name, home + "/media", "file", Int64(48_234_496 + i * 211_000_000), ago: Double(i) * 9 + 2, measure: Double(42 + i * 187))
        }
    }
    static var audio: [NativeServerFileRow] {
        ["voice-note-ahmad.m4a", "podcast-ep12.mp3", "hold-music.mp3", "call-2026-10-08.wav", "jingle-final.mp3", "interview-raw.flac"].enumerated().map { i, name in
            row(name, home + (i % 2 == 0 ? "/media/audio" : "/uploads/calls"), "file", Int64(1_200_000 + i * 7_300_000), ago: Double(i) * 3 + 1, measure: Double(38 + i * 412))
        }
    }
    static var documents: [NativeServerFileRow] {
        ["invoice-september.pdf", "contract-blackhawks.pdf", "pitch-deck-q4.pptx", "salaries-2026.xlsx", "brand-guide.pdf", "privacy-policy.docx"].enumerated().map { i, name in
            row(name, home + (i < 3 ? "/docs" : "/uploads/2026-10"), "file", Int64(184_320 + i * 1_311_000), ago: Double(i) * 5 + 1, measure: name.hasSuffix(".pdf") ? Double(3 + i * 7) : nil)
        }
    }
    static let counts: [String: (Int, Int64)] = ["photo": (1_240, 3_328_599_654), "video": (5, 2_400_000_000), "audio": (6, 120_000_000), "document": (6, 18_000_000)]

    func filesView(_ view: String, server: CodingAIServer, lookOnly: Bool) -> NativeServerFilesView {
        let files = NativeServerFilesModel(serverID: server.id, serverName: server.name, live: false, fixture: (Self.home, Self.folderRows, lookOnly))
        files.selection = Self.home + "/README.md"
        files.fixturePreviews = [Self.home + "/README.md": .text(Self.readme, total: 4_812)]
        let type = ["Photos": "photo", "Videos": "video", "Audio": "audio", "Documents": "document"][view] ?? "photo"
        let rows = ["photo": Self.photos, "video": Self.videos, "audio": Self.audio, "document": Self.documents][type] ?? []
        let gallery = NativeServerGalleryModel(fixture: server.id, type: type, rows: rows, counts: Self.counts,
                                               scannedAt: Self.now.addingTimeInterval(-600), group: type == "photo" ? "month" : "none")
        gallery.total = Self.counts[type]?.0 ?? rows.count
        gallery.bytes = Self.counts[type]?.1 ?? 0
        var images: [String: NSImage] = [:]
        for (i, r) in (Self.photos + Self.videos).enumerated() { images[r.path] = Self.picture(i) }
        if type == "photo" { gallery.selection = Self.photos[1].path }
        return NativeServerFilesView(serverID: server.id, serverName: server.name, live: false, initialView: view,
                                     filesFixture: files, galleryFixture: gallery, fixtureImages: images)
    }

    func testWordsAndRows() throws {
        XCTAssertEqual(NativeServerFilesWords.size(2_400_000_000), ByteCountFormatter.string(fromByteCount: 2_400_000_000, countStyle: .file))
        XCTAssertEqual(NativeServerFilesWords.duration(187), "3:07")
        XCTAssertEqual(NativeServerFilesWords.duration(3_725), "1:02:05")
        let row = try XCTUnwrap(NativeServerFileRow(CodingAIJSON(["name": "a.mp3", "path": "/h/a.mp3", "kind": "file", "type": "audio", "size": 10.0, "modified": 1_000.0, "seconds": 61.0])))
        XCTAssertEqual(row.kindWord, "Audio"); XCTAssertEqual(row.measure, 61); XCTAssertEqual(row.folder, "/h")
        let files = NativeServerFilesModel(serverID: "s", serverName: "S", live: false, fixture: ("/home/deploy", [], true))
        files.path = "/home/deploy/media/2026"; files.root = "/home/deploy"; files.roots = ["/home/deploy"]
        XCTAssertEqual(files.crumbs.map(\.label), ["Home", "media", "2026"])
        XCTAssertEqual(files.crumbs.last?.path, "/home/deploy/media/2026")
    }

    func testRealWindowRenders() throws {
        guard ProcessInfo.processInfo.environment["SRVFILES_REAL_WINDOW"] == "1" else { throw XCTSkip("real-window renders run on request") }
        NSApplication.shared.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: "/Users/imatch/Projects/Personal/td-native-shell/macos/design-2026-10-10/built.noindex")
        let model = MACHINESRenderEvidence.fixtureModel()
        let server = try XCTUnwrap(model.servers.first)
        let state = model.states[server.id]
        let access = NativeServerAccessModel(fixture: server.id, lookOnly: true, sshAlias: "imza-server", keys: [], allowed: [])
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            for view in ["Folders", "Photos", "Videos", "Audio", "Documents"] {
                let page = NativeServerPage(model: model, server: server, route: .constant(.list), accessFixture: access, live: false,
                    fixtureState: state, projectId: "imatch", initialView: "Files", filesFixture: filesView(view, server: server, lookOnly: view != "Folders" || !dark))
                try capture(page, size: CGSize(width: 1180, height: 900), dark: dark, to: output.appendingPathComponent("SRVFILES-\(view.lowercased())-\(theme).png"))
            }
            let empty = NativeServerGalleryModel(fixture: server.id, type: "video", rows: [], counts: [:], scannedAt: nil)
            let emptyView = NativeServerFilesView(serverID: server.id, serverName: server.name, live: false, initialView: "Videos",
                filesFixture: NativeServerFilesModel(serverID: server.id, serverName: server.name, live: false, fixture: (Self.home, [], true)), galleryFixture: empty)
            try capture(NativeServerPage(model: model, server: server, route: .constant(.list), accessFixture: access, live: false, fixtureState: state,
                projectId: "imatch", initialView: "Files", filesFixture: emptyView), size: CGSize(width: 1180, height: 900), dark: dark,
                to: output.appendingPathComponent("SRVFILES-not-searched-\(theme).png"))
            let limits = NativeServerFolderLimitsModel(serverID: server.id, live: false, fixtureSaved: ["~", "/srv/media"], fixtureRoots: ["/home/deploy", "/srv/media"])
            try capture(MACHINESServerSettingsContent(model: model, server: server, accessFixture: access, live: false, folderLimitsFixture: limits),
                size: CGSize(width: 560, height: 900), dark: dark, to: output.appendingPathComponent("SRVFILES-settings-folders-\(theme).png"))
        }
    }

    private func capture<V: View>(_ view: V, size: CGSize, dark: Bool, to file: URL) throws {
        let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(DeckTokens.page).environment(\.colorScheme, dark ? .dark : .light))
        window.order(.below, relativeTo: 0)
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.4))
        XCTAssertFalse(NSApp.isActive)
        let shot = Process()
        shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
        try shot.run(); shot.waitUntilExit()
        window.orderOut(nil); window.contentView = nil; window.close()
        XCTAssertEqual(shot.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), file.lastPathComponent)
        print("SRVFILES real window \(file.lastPathComponent)")
    }

    /// #483: a finished thumbnail load hands its slot straight to the one waiting; a newcomer in between waits too.
    func testThumbnailSlotsNeverAdmitMoreThanTheLimit() async {
        let slots = NativeServerThumbSlots(limit: 1), order = SRVFILESOrder()
        await slots.take()
        let waiter = Task { @MainActor in await slots.take(); order.items.append("waiter") }
        while slots.waitingCount == 0 { await Task.yield() }
        slots.give()
        XCTAssertEqual(slots.running, 1)
        await waiter.value
        let newcomer = Task { @MainActor in await slots.take(); order.items.append("newcomer") }
        while slots.waitingCount == 0, !order.items.contains("newcomer") { await Task.yield() }
        XCTAssertEqual(order.items, ["waiter"]); XCTAssertEqual(slots.running, 1)
        slots.give()
        await newcomer.value
        XCTAssertEqual(order.items, ["waiter", "newcomer"])
        slots.give()
        XCTAssertEqual(slots.running, 0)
    }
}

@MainActor private final class SRVFILESOrder { var items: [String] = [] }
