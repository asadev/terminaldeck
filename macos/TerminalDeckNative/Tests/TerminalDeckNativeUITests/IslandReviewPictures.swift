import AppKit
import SwiftUI
import Testing
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

/// 15 Nov review (items 47, 62; DESIGN.md section 5). Pictures, light and dark, written to
/// `macos/night/codex/island-review-evidence/`: the resting capsule for every "Shows" choice in every size and both
/// looks, drawn by the real island pieces (IslandView on its canvas), and the Settings page with its preview.
/// No app start, window, store or network.
@Suite("Dynamic Island — review pictures")
@MainActor
struct IslandReviewPictures {
    static let facts = NativeIslandFacts(hootLine: "Commander is working", hootQuiet: false, hootWorking: true,
        sessions: [.init(id: "s1", name: "Website copy", status: "working"), .init(id: "s2", name: "Release notes", status: "input")],
        tasks: [.init(id: "t1", title: "Send the November invoice", updatedAt: 1_763_200_000_000, due: "2026-11-18"),
                .init(id: "t2", title: "Check the phone build", updatedAt: 1_763_100_000_000, due: nil)],
        waiting: [.init(id: "consent:a", asker: "Commander", sessionID: nil)])
    static let plain = IslandScreen(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1056))

    private func output() throws -> URL {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.deletingLastPathComponent().appendingPathComponent("night/codex/island-review-evidence")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return out
    }

    private func write(_ view: AnyView, size: NSSize, dark: Bool, to url: URL) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height).background(DeckTokens.page))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.layoutSubtreeIfNeeded()
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        let png = try #require(image.representation(using: .png, properties: [:]))
        try png.write(to: url)
        #expect(image.pixelsWide >= Int(size.width))
    }

    @Test func capsuleForEveryShowsChoiceSizeAndLook() throws {
        let out = try output()
        for shows in NativeIslandShows.allCases { for width in FIXESIslandOptions.Width.allCases {
            for look in FIXESIslandOptions.Look.allCases { for dark in [false, true] {
                let options = FIXESIslandOptions(look: look, width: width)
                let model = IslandViewModel(layout: FIXESIslandDisplayPolicy.layout(for: Self.plain, options: options, quiet: false))
                model.engineUp = true; model.pageLoaded = true
                model.appearance = dark ? "dark" : "light"; model.options = options; model.shows = shows
                model.suppliedFacts = Self.facts; model.quiet = false
                let layout = model.layout
                #expect(layout.pill.height == 32); #expect(layout.pill.radius == 16); #expect(layout.pill.width == width.resting)
                let canvas = layout.expandedFrame.size
                let view = IslandView(model: model, suppliedContent: AnyView(EmptyView()))
                    .frame(width: canvas.width, height: canvas.height, alignment: .top)
                    .frame(width: canvas.width, height: 64, alignment: .top).clipped()
                try write(AnyView(view), size: NSSize(width: canvas.width, height: 64), dark: dark,
                    to: out.appendingPathComponent("capsule-\(shows.rawValue)-\(width.rawValue)-\(look == .dark ? "always-dark" : "match")-\(dark ? "dark" : "light").png"))
            }}
        }}
    }

    @Test func settingsPageForEveryShowsChoice() throws {
        let out = try output()
        let displays = [NativeIslandSettingsModel.Display(id: "a", name: "Built-in Retina Display", builtIn: true),
                        NativeIslandSettingsModel.Display(id: "b", name: "Studio Display", builtIn: false)]
        for shows in NativeIslandShows.allCases { for dark in [false, true] {
            let model = NativeIslandSettingsModel(fixtureValues: [NativeIslandSettingsModel.showsKey: .string(shows.rawValue)],
                fixtureDisplays: displays)
            #expect(model.shows == shows)
            let page = DeckSettingsScaffold(title: "Dynamic Island") { NativeIslandSettingsContent(model: model, facts: Self.facts) }
            try write(AnyView(page), size: NSSize(width: 700, height: 520), dark: dark,
                to: out.appendingPathComponent("settings-\(shows.rawValue)-\(dark ? "dark" : "light").png"))
        }}
    }
}

/// The choice -> content mapping: glyph, one line, one mark, and when it counts as quiet.
@Suite("Dynamic Island — what Shows displays")
@MainActor
struct IslandShowsMappingTests {
    let facts = IslandReviewPictures.facts

    @Test func hootKeepsTodaysLineAndMarks() {
        let face = NativeIslandFace.make(shows: .hoot, facts: facts)
        #expect(face.glyph == .hoot)
        #expect(face.line == "Commander is working")
        #expect(face.mark == .count(1, attention: true))
        #expect(!face.quiet)
        var calm = facts; calm.sessions = []
        #expect(NativeIslandFace.make(shows: .hoot, facts: calm).mark == .working)
        calm.hootQuiet = true; calm.hootWorking = false
        let quiet = NativeIslandFace.make(shows: .hoot, facts: calm)
        #expect(quiet.line == "All quiet"); #expect(quiet.mark == .none); #expect(quiet.quiet)
    }

    @Test func runningSessionsShowTheNewestNameAndTheCount() {
        var withDone = facts
        withDone.sessions.append(.init(id: "s3", name: "Old job", status: "exited"))
        let face = NativeIslandFace.make(shows: .sessions, facts: withDone)
        #expect(face.glyph == .symbol("terminal"))
        #expect(face.line == "Release notes")
        #expect(face.mark == .count(2, attention: true))
        let none = NativeIslandFace.make(shows: .sessions, facts: NativeIslandFacts())
        #expect(none.line == "No sessions running"); #expect(none.mark == .none); #expect(none.quiet)
    }

    @Test func tasksShowTheNewestOpenTaskAndTheCount() {
        let face = NativeIslandFace.make(shows: .tasks, facts: facts)
        #expect(face.glyph == .symbol("checklist"))
        #expect(face.line == "Send the November invoice")
        #expect(face.mark == .count(2, attention: false))
        #expect(NativeIslandFace.make(shows: .tasks, facts: NativeIslandFacts()).line == "No open tasks")
        var done = TaskRow(id: "x", title: "Done one"); done.completedAt = 1
        let open = TaskRow(id: "y", title: "Open one")
        #expect(NativeIslandFacts.openTasks([done, open]).map(\.title) == ["Open one"])
    }

    @Test func onlyWhatNeedsMeCountsApprovalsAndAskingSessions() {
        let waiting = NativeIslandFacts.waiting(desk: [], sessions: facts.sessions)
        #expect(waiting.map(\.asker) == ["Release notes"])
        var asked = facts; asked.waiting = waiting + facts.waiting
        let face = NativeIslandFace.make(shows: .needsMe, facts: asked)
        #expect(face.glyph == .symbol("bell"))
        #expect(face.line == "Release notes needs you")
        #expect(face.mark == .count(2, attention: true))
        let none = NativeIslandFace.make(shows: .needsMe, facts: NativeIslandFacts())
        #expect(none.line == "Nothing needs you"); #expect(none.quiet)
    }

    @Test func neverAnIdOrAPath() {
        #expect(NativeIslandFace.shown("/Users/someone/Projects/site", or: "Session") == "site")
        #expect(NativeIslandFace.shown("3f2a9c1e-77b0-4d2e-9a11-0c5b6d7e8f90", or: "Session") == "Session")
        #expect(NativeIslandFace.shown("two\nlines", or: "x") == "two lines")
    }

    @Test func storedChoiceDefaultsToHoot() {
        #expect(NativeIslandShows(stored: nil) == .hoot)
        #expect(NativeIslandShows(stored: "nonsense") == .hoot)
        #expect(NativeIslandShows(stored: "needs-me") == .needsMe)
        let preferences = NativeFIXESIslandPreferences(values: .object([.init(NativeFIXESIslandPreferences.showsKey, .string("tasks"))]))
        #expect(preferences.shows == .tasks)
        #expect(preferences.read()["shows"].string == "tasks")
    }
}
