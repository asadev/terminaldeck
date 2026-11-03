import Foundation
import XCTest
import TerminalDeckBackend
@testable import TerminalDeckNative

/// CONNECT-SKILLS (11 Oct): the Skills page's shared folders. Codex's own bundled skills were labelled
/// "Terminal Deck · built in"; they are Codex's. Terminal Deck's starter set is its own built-in root.
final class CONNECTSkillRootsTests: XCTestCase {
    @MainActor func testSkillsPageLabelsEachBuiltInByWhoShipsIt() {
        let home = URL(fileURLWithPath: "/Users/someone"), codex = URL(fileURLWithPath: "/Users/someone/.codex")
        let app = URL(fileURLWithPath: "/Applications/Terminal Deck.app/Contents/Resources/built-in-skills")
        let roots = NativeCompositionProduction.skillRoots(home: home, codexHome: codex, builtIn: app)
        XCTAssertEqual(roots.map(\.source), ["Every project · .claude/skills", "Terminal Deck · built in", "Codex · built in"])
        XCTAssertEqual(roots.map(\.folder.path), ["/Users/someone/.claude/skills", app.path, "/Users/someone/.codex/skills/.system"])
        XCTAssertEqual(roots.map(\.builtIn), [false, true, true])
        // A copy of the app without the folder lists no Terminal Deck built-ins, and never relabels Codex's.
        XCTAssertEqual(NativeCompositionProduction.skillRoots(home: home, codexHome: codex, builtIn: nil).map(\.source),
                       ["Every project · .claude/skills", "Codex · built in"])
    }
}
