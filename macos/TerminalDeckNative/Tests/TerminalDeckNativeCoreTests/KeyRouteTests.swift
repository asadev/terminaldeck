import Foundation
import Testing
@testable import TerminalDeckNativeCore

@Suite("Key routing (mirrors keymap.test.ts resolveCommand)")
struct KeyRouteTests {
    @Test func resolvesTheSameCommandsThePageDoes() {
        let palette = Keymap.resolve(KeyStroke(key: "k", meta: true), scope: .global)
        #expect(palette != nil && palette?.keys.contains("mod+k") == true)
        #expect(Keymap.resolve(KeyStroke(key: "k"), scope: .global) == nil)
        #expect(Keymap.resolve(KeyStroke(key: "k", ctrl: true), scope: .global, isMac: true)?.keys.contains("mod+k") != true)
        #expect(Keymap.resolve(KeyStroke(key: "k", ctrl: true), scope: .global, isMac: false)?.keys.contains("mod+k") == true)
    }

    @Test func aTerminalKeepsWhatDoesNotSteal() {
        #expect(Keymap.stealsFromTerminal(Chord(mod: true, key: "k")))
        #expect(!Keymap.stealsFromTerminal(Chord(ctrl: true, key: "c")))
        #expect(Keymap.stealsFromTerminal(Chord(key: "f5")))
        #expect(Keymap.stealsFromTerminal(Chord(ctrl: true, key: "tab")))
        #expect(!Keymap.stealsFromTerminal(Chord(mod: true, key: "k"), isMac: false))
        #expect(Keymap.bindings(in: .terminal).allSatisfy { $0.scope != .modal && !$0.passthrough })
        #expect(Keymap.bindings(in: .global).allSatisfy { $0.scope == .global })
        #expect(Keymap.bindings(in: .modal).allSatisfy { $0.scope == .modal })
    }

    @Test func tabDigits() {
        #expect(Keymap.tabDigit(KeyStroke(key: "3", meta: true)) == 3)
        #expect(Keymap.tabDigit(KeyStroke(key: "3", meta: true, shift: true)) == nil)
        #expect(Keymap.tabDigit(KeyStroke(key: "0", meta: true)) == nil)
        #expect(Keymap.tabDigit(KeyStroke(key: "3")) == nil)
    }

    @Test func tokensLikeKeyToken() {
        #expect(Keymap.token(keyCode: 53, characters: "\u{1b}") == "escape")
        #expect(Keymap.token(keyCode: 40, characters: "K") == "k")
        #expect(Keymap.token(keyCode: 40, characters: "˚") == "k")   // ⌥K
        #expect(Keymap.token(keyCode: 18, characters: "!") == "1")   // ⇧1
        #expect(Keymap.token(keyCode: 44, characters: "?") == "/")   // ⇧/
        #expect(Keymap.token(keyCode: 49, characters: " ") == "space")
        #expect(Keymap.token(keyCode: 96, characters: nil) == "f5")
        #expect(Keymap.token(keyCode: 13, characters: "z") == "z")    // another layout keeps its letter
    }
}

@Suite("Onboarding (mirrors Onboarding.tsx)")
struct OnboardingTests {
    @Test func wordsAndSplit() {
        let tools = [
            CodingAITool(id: "git", label: "Git", state: .ready, purpose: "Diffs"),
            CodingAITool(id: "claude", label: "Claude Code", state: .missing, purpose: "Agent", remedy: "Install it", url: "https://x"),
            CodingAITool(id: "codex", label: "Codex", state: .installedNotAuthed, version: "0.5 (codex)"),
        ]
        let split = Onboarding.split(tools)
        #expect(split.agents.map(\.id) == ["claude", "codex"])
        #expect(split.extras.map(\.id) == ["git"])
        #expect(Onboarding.agentLine(tools[1]) == "Install it")
        #expect(Onboarding.stateLabel(.installedNotAuthed) == "Sign in needed")
        #expect(Onboarding.stateLabel(.missing) == "Not installed")
        #expect(Onboarding.title("Terminal Deck") == "Welcome to Terminal Deck")
    }

    @Test func versionLabelDropsARepeatedName() {
        #expect(Onboarding.trimRepeatedName("2.1.233 (Claude Code)", label: "Claude Code") == "2.1.233")
        #expect(Onboarding.trimRepeatedName("2.1.233 (beta)", label: "Claude Code") == "2.1.233 (beta)")
        #expect(Onboarding.trimRepeatedName("(Claude Code)", label: "Claude Code") == "(Claude Code)")
        #expect(Onboarding.versionLabel(CodingAITool(id: "c", label: "Codex", state: .ready, version: "0.5 (codex)")) == "0.5")
        #expect(Onboarding.versionLabel(CodingAITool(id: "c", label: "Codex", state: .missing)) == nil)
        #expect(Onboarding.versionLabel(CodingAITool(id: "c", label: "Codex", state: .ready)) == CodingAITool.noVersion)
    }
}
