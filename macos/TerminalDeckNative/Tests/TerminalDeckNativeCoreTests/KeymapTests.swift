import Foundation
import Testing
@testable import TerminalDeckNativeCore

@Suite("Keymap (mirrors src/renderer/keymap.test.ts)")
struct KeymapTests {
    static let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("src/renderer/keymap.ts")

    @Test func parsesChords() {
        #expect(Chord.parse("mod+shift+t") == Chord(mod: true, shift: true, key: "t"))
        #expect(Chord.parse("shift+mod+t") == Chord.parse("mod+shift+t"))
        #expect(Chord.parse("MOD+Shift+T") == Chord.parse("mod+shift+t"))
        #expect(Chord.parse("cmd+k") == Chord.parse("mod+k"))
        #expect(Chord.parse("option+k") == Chord.parse("alt+k"))
        #expect(Chord.parse("control+k") == Chord.parse("ctrl+k"))
        #expect(Chord.parse("mod") == nil)
        #expect(Chord.parse("") == nil)
        #expect(Chord.parse("mod+mod+t") == nil)
        #expect(Chord.parse("mod+t+u") == nil)
        #expect(Chord.parse("+") == Chord(key: "+"))
        #expect(Chord.parse("mod+shift+k")?.text == "mod+shift+k")
    }

    @Test func formatsForTheMac() {
        #expect(Chord.parse("mod+shift+t")?.formatted(mac: true) == "⌘⇧T")
        #expect(Chord.parse("mod+t")?.formatted(mac: true) == "⌘T")
        #expect(Chord.parse("mod+,")?.formatted(mac: true) == "⌘,")
        #expect(Chord.parse("mod+\\")?.formatted(mac: true) == "⌘\\")
        #expect(Chord.parse("ctrl+shift+tab")?.formatted(mac: true) == "⌃⇧⇥")
        #expect(Chord.parse("escape")?.formatted(mac: true) == "Esc")
        #expect(Chord.parse("mod+enter")?.formatted(mac: true) == "⌘↩")
    }

    @Test func formatsForOtherSystems() {
        #expect(Chord.parse("mod+shift+t")?.formatted(mac: false) == "Ctrl+Shift+T")
        #expect(Chord.parse("mod+1")?.formatted(mac: false) == "Ctrl+1")
        #expect(Chord.parse("mod+ctrl+k")?.formatted(mac: false) == "Ctrl+K", "one Ctrl, not two")
    }

    @Test func rangesAndLookups() {
        let jump = Keymap.all.first { $0.id == "session.jump" }!
        #expect(jump.formatted(mac: true) == ["⌘1–9"])
        #expect(Keymap.all.first { $0.id == "palette.commands" }!.formatted() == ["⌘K", "⌘⇧P"])
        #expect(Keymap.chord(for: "project.open") == "⌘O")
        #expect(Keymap.chord(for: "session.new") == "⌘T")
        #expect(Keymap.chord(for: "terminal.interrupt") == nil, "passthrough is never offered")
        #expect(Keymap.chord(for: "nope") == nil)
        #expect(Keymap.tip("Settings", "app.preferences") == "Settings (⌘,)")
        #expect(Keymap.tip("Thing", "nope") == "Thing")
    }

    @Test func groupsAndSearch() {
        let groups = Keymap.grouped()
        #expect(groups.map(\.title) == ["Anywhere", "In a session", "In a dialog"])
        #expect(groups.flatMap(\.bindings).count == Keymap.all.count)
        #expect(Keymap.search("").count == Keymap.all.count)
        #expect(Keymap.search("terminal clear").map(\.id) == ["terminal.clear"])
        #expect(Keymap.search("⌘,").map(\.id) == ["app.preferences"])
        #expect(Keymap.search("SIDEBAR").map(\.id) == ["view.sidebar"])
    }

    /// Every entry of KEYMAP in keymap.ts, in order, field for field.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: source.path)))
    func sameTableAsKeymapTs() throws {
        let text = try String(contentsOf: Self.source, encoding: .utf8)
        let start = try #require(text.range(of: "export const KEYMAP"))
        let end = try #require(text.range(of: "\n]\n", range: start.upperBound..<text.endIndex))
        let table = String(text[start.upperBound..<end.lowerBound])
        // Each `{ … }` entry, however it is wrapped.
        let entries = table.components(separatedBy: "{").dropFirst().map { $0.components(separatedBy: "}").first ?? "" }
        func field(_ name: String, _ entry: String) -> String? {
            guard let r = entry.range(of: #"\b\#(name): '((?:[^'\\]|\\.)*)'"#, options: .regularExpression) else { return nil }
            let match = String(entry[r])
            return String(match.drop { $0 != "'" }.dropFirst().dropLast()).replacingOccurrences(of: "\\\\", with: "\\")
        }
        func keys(_ entry: String) -> [String] {
            guard let r = entry.range(of: #"keys: \[[^\]]*\]"#, options: .regularExpression) else { return [] }
            return entry[r].split(separator: "'").enumerated().filter { $0.offset % 2 == 1 }
                .map { String($0.element).replacingOccurrences(of: "\\\\", with: "\\") }
        }
        let web = entries.map { e in
            KeyBinding(field("id", e) ?? "?", keys(e), field("label", e) ?? "?", KeyScope(rawValue: field("scope", e) ?? "") ?? .modal,
                       field("group", e) ?? "?", passthrough: e.contains("passthrough: true"), collapseRange: e.contains("collapse: 'range'"))
        }
        #expect(web.count == Keymap.all.count)
        for (a, b) in zip(web, Keymap.all) { #expect(a == b, "\(a.id) differs from keymap.ts") }
    }
}

@Suite("Shortcuts sheet")
struct ShortcutsSheetTests {
    @Test func featureCommands() {
        #expect(FeatureCommands.hidden(featureState: [:]).isEmpty, "both default on")
        #expect(FeatureCommands.hidden(featureState: ["split": "off"]) == ["pane.split", "pane.focusLeft", "pane.focusRight", "pane.close"])
        #expect(FeatureCommands.hidden(featureState: ["swarm": "uninstalled"]) == ["view.swarm"])
        #expect(FeatureCommands.hidden(featureState: ["swarm": "nonsense"]).isEmpty, "unknown values fall back to the default")
        #expect(!Keymap.live(hidden: ["view.swarm"]).contains { $0.id == "view.swarm" })
    }

    @Test func countsAndEmpty() {
        #expect(Keymap.countLabel(query: "", matches: 3, live: 30) == "30")
        #expect(Keymap.countLabel(query: "split", matches: 3, live: 30) == "3 of 30")
        #expect(Keymap.emptyLabel(query: "  ") == "No shortcuts to show.")
        #expect(Keymap.emptyLabel(query: " zz ") == "Nothing matches “zz”.")
    }
}
