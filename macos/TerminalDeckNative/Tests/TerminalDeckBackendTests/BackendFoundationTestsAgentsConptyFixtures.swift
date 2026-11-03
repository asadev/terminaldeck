import Foundation
import XCTest
@testable import TerminalDeckBackend

/// Recorded screen fixtures are portable parser inputs. This does not start
/// ConPTY or claim Windows runtime coverage. The missing agent/refusal readers
/// are separately counted in the handoff.
final class BackendFoundationTestsAgentsConptyFixtures: XCTestCase {
    private struct Capture: Decodable {
        struct Environment: Decodable {
            struct Shot: Decodable { let label: String, screen: String }
            let shots: [Shot]
        }
        let environments: [String: Environment]
    }
    private func shots(_ run: (String, [Capture.Environment.Shot]) throws -> Void) throws {
        let capture = try JSONDecoder().decode(Capture.self, from: Data(Self.recorded.utf8))
        for name in ["withTerm", "withoutTerm"] { try run(name, try XCTUnwrap(capture.environments[name]).shots) }
    }
    private func shot(_ shots: [Capture.Environment.Shot], _ name: String) throws -> String {
        try XCTUnwrap(shots.first { $0.label == name }).screen
    }
    private func kind(_ screen: String) -> String {
        switch BackendTaskBriefDelivery.composer(screen) {
        case .ready: return "ready"
        case .typing: return "typing"
        case .choosing: return "choosing"
        case .working: return "working"
        case .unknown: return "unknown"
        }
    }
    // agent-controls-conpty.test.ts:96, both recorded environments.
    func testRecordedBootScreensAreReady() throws {
        try shots { name, shots in XCTAssertEqual(kind(try shot(shots, "idle-after-boot")), "ready", name) }
    }
    // agent-controls-conpty.test.ts:100
    func testRecordedUnsentSlashCommandsAreReadExactly() throws {
        try shots { name, shots in
            for (label, expected) in [("typed-slash-model", "/model"), ("typed-slash-effort", "/effort")] {
                guard case .typing(let text) = BackendTaskBriefDelivery.composer(try shot(shots, label)) else { XCTFail("Expected typing: " + name + "/" + label); continue }
                XCTAssertEqual(text, expected, name)
            }
        }
    }
    // agent-controls-conpty.test.ts:117 composer clause. refuseToType is absent.
    func testRecordedNumberedPickerIsChoosing() throws {
        try shots { name, shots in
            guard case .choosing(let asking) = BackendTaskBriefDelivery.composer(try shot(shots, "model-picker-open")) else { return XCTFail("Expected choosing: " + name) }
            XCTAssertTrue(asking.contains("1. Default (recommended)"), name)
        }
    }
    // agent-controls-conpty.test.ts:127
    func testRecordedDismissedPickerReturnsToBottomPrompt() throws {
        try shots { name, shots in
            let screen = try shot(shots, "after-escape")
            XCTAssertTrue(screen.contains("Kept model as Opus 5"), name); XCTAssertEqual(kind(screen), "ready", name)
        }
    }
    // agent-controls-conpty.test.ts:137
    func testRecordedControlURollbackReturnsToReady() throws {
        try shots { name, shots in
            let screen = try shot(shots, "after-ctrl-u")
            XCTAssertTrue(screen.contains("Ctrl+Y to paste deleted text"), name); XCTAssertEqual(kind(screen), "ready", name)
        }
    }
    // agent-controls-conpty.test.ts:145
    func testNoRecordedScreenIsUnknown() throws {
        try shots { name, shots in
            for entry in shots { XCTAssertNotEqual(kind(entry.screen), "unknown", name + "/" + entry.label) }
        }
    }
    // Verbatim src/main/agent-controls.conpty.json; no local/remote process.
    private static let recorded = ###"""
{
  "capturedOn": "DESKTOP-DDGMNCV, Windows 11 Pro 10.0.26200",
  "capturedAt": "2026-08-17",
  "cli": "claude 2.1.233",
  "spawn": "%COMSPEC% /c C:\\\\Users\\\\Kiwi\\\\.local\\\\bin\\\\claude.exe",
  "pty": "node-pty 1.1.0, ConPTY",
  "emulator": "@xterm/headless, cols 100 rows 30, scrollback 200, translateToString(true)",
  "environments": {
    "withTerm": {
      "env": "TERM=xterm-256color, COLORTERM=truecolor — what pty-manager.ts sets for every session",
      "pointer": "❯",
      "shots": [
        {
          "label": "idle-after-boot",
          "screen": "╭─── Claude Code v2.1.233 ─────────────────────────────────────────────────────────────────────────╮\n│                                                    │ Tips for getting started                    │\n│                 Welcome back Asad!                 │ Run /init to create a CLAUDE.md file with … │\n│                                                    │ ─────────────────────────────────────────── │\n│                       ▐▛███▜▌                      │ What's new                                  │\n│                      ▝▜█████▛▘                     │ Added GitLab merge request URL support to … │\n│                        ▘▘ ▝▝                       │ Added an opt-in `forward_user_identity` ap… │\n│   Opus 5 (1M context) with xhig… · Claude Max ·    │ Added opt-in memory cgroup support for Bas… │\n│   examplemail@gmail.com's Organization             │ /release-notes for more                     │\n│                    C:\\td-build                     │                                             │\n╰──────────────────────────────────────────────────────────────────────────────────────────────────╯\n\n\n────────────────────────────────────────────────────────────────────────────────────────────────────\n❯ \n────────────────────────────────────────────────────────────────────────────────────────────────────\n  ⏵⏵ don't ask on (shift+tab to cycle) · ← for agents\n\n\n\n\n\n\n\n\n\n\n\n\n"
        },
        {
          "label": "typed-slash-model",
          "screen": "│                 Welcome back Asad!                 │ Run /init to create a CLAUDE.md file with … │\n│                                                    │ ─────────────────────────────────────────── │\n│                       ▐▛███▜▌                      │ What's new                                  │\n│                      ▝▜█████▛▘                     │ Added GitLab merge request URL support to … │\n│                        ▘▘ ▝▝                       │ Added an opt-in `forward_user_identity` ap… │\n│   Opus 5 (1M context) with xhig… · Claude Max ·    │ Added opt-in memory cgroup support for Bas… │\n│   examplemail@gmail.com's Organization             │ /release-notes for more                     │\n│                    C:\\td-build                     │                                             │\n╰──────────────────────────────────────────────────────────────────────────────────────────────────╯\n\n\n────────────────────────────────────────────────────────────────────────────────────────────────────\n❯ /model\n────────────────────────────────────────────────────────────────────────────────────────────────────\n/model                        Set the AI model for Claude Code (currently Opus 5 (1M context))\n/claude-api                   Reference for the Claude API / Anthropic SDK — model ids, pricing,\n                              params, streaming, tool use, MCP, agents, caching, token counting…\n/loop                         Run a prompt or slash command on a recurring interval (e.g. /loop\n                              5m /foo). Omit the interval to let the model self-pace.\n/advisor                      Let Claude consult a stronger model at key moments\n/effort                       Set effort level for model usage\n/status                       Show Claude Code status including version, model, account, API\n                              connectivity, and tool statuses\n/auto-mode-setup              Set up and customise auto mode — environment context, plus\n                              optional rule tweaks\n/doctor                       Health-check the user's Claude Code setup and fix issues: diagnose\n                              installation health — what the `claude doctor` terminal diagnosti…\n/update-config                Use this skill to configure the Claude Code harness via\n                              settings.json. Automated behaviors (\"from now on when X\", \"each t…    \n"
        },
        {
          "label": "model-picker-open",
          "screen": "╭─── Claude Code v2.1.233 ─────────────────────────────────────────────────────────────────────────╮\n│                                                    │ Tips for getting started                    │\n│                 Welcome back Asad!                 │ Run /init to create a CLAUDE.md file with … │\n│                                                    │ ─────────────────────────────────────────── │\n│                       ▐▛███▜▌                      │ What's new                                  │\n│                      ▝▜█████▛▘                     │ Added GitLab merge request URL support to … │\n│                        ▘▘ ▝▝                       │ Added an opt-in `forward_user_identity` ap… │\n│   Opus 5 (1M context) with xhig… · Claude Max ·    │ Added opt-in memory cgroup support for Bas… │\n│   examplemail@gmail.com's Organization             │ /release-notes for more                     │\n│                    C:\\td-build                     │                                             │\n╰──────────────────────────────────────────────────────────────────────────────────────────────────╯\n\n\n❯ /model\n\n────────────────────────────────────────────────────────────────────────────────────────────────────\n  Select model\n  Switch between Claude models. Your pick becomes the default for new sessions. For other/previous  \n  model names, specify with --model.\n\n  ❯ 1. Default (recommended) ✔  Opus 5 with 1M context · Best for everyday, complex tasks\n    2. Opus (1M context)        Opus 5 with 1M context · Best for everyday, complex tasks\n    3. Fable                    Fable 5 · Most capable for your hardest and longest-running tasks   \n    4. Sonnet                   Sonnet 5 · Efficient for routine tasks\n    5. Haiku                    Haiku 4.5 · Fastest for quick answers\n\n  ◉ xHigh effort ←/→ to adjust\n\n  Enter to set as default · s to use this session only · Esc to cancel\n"
        },
        {
          "label": "after-escape",
          "screen": "╭─── Claude Code v2.1.233 ─────────────────────────────────────────────────────────────────────────╮\n│                                                    │ Tips for getting started                    │\n│                 Welcome back Asad!                 │ Run /init to create a CLAUDE.md file with … │\n│                                                    │ ─────────────────────────────────────────── │\n│                       ▐▛███▜▌                      │ What's new                                  │\n│                      ▝▜█████▛▘                     │ Added GitLab merge request URL support to … │\n│                        ▘▘ ▝▝                       │ Added an opt-in `forward_user_identity` ap… │\n│   Opus 5 (1M context) with xhig… · Claude Max ·    │ Added opt-in memory cgroup support for Bas… │\n│   examplemail@gmail.com's Organization             │ /release-notes for more                     │\n│                    C:\\td-build                     │                                             │\n╰──────────────────────────────────────────────────────────────────────────────────────────────────╯\n\n\n❯ /model\n  ⎿  Kept model as Opus 5 (1M context) (default)\n\n────────────────────────────────────────────────────────────────────────────────────────────────────\n❯ \n────────────────────────────────────────────────────────────────────────────────────────────────────\n  ⏵⏵ don't ask on (shift+tab to cycle) · ← for agents                            ◉ xhigh · /effort\n\n\n\n\n\n\n\n\n\n"
        },
        {
          "label": "typed-slash-effort",
          "screen": "│                      ▝▜█████▛▘                     │ Added GitLab merge request URL support to … │\n│                        ▘▘ ▝▝                       │ Added an opt-in `forward_user_identity` ap… │\n│   Opus 5 (1M context) with xhig… · Claude Max ·    │ Added opt-in memory cgroup support for Bas… │\n│   examplemail@gmail.com's Organization             │ /release-notes for more                     │\n│                    C:\\td-build                     │                                             │\n╰──────────────────────────────────────────────────────────────────────────────────────────────────╯\n\n\n❯ /model\n  ⎿  Kept model as Opus 5 (1M context) (default)\n\n────────────────────────────────────────────────────────────────────────────────────────────────────\n❯ /effort\n────────────────────────────────────────────────────────────────────────────────────────────────────\n/effort                       Set effort level for model usage\n/code-review                  3 free /ultrareview · Review the current diff, or a PR\n                              number/branch/path target, for correctness bugs and reuse/simplif…\n\n\n\n\n\n\n\n\n\n\n\n\n"
        },
        {
          "label": "after-ctrl-u",
          "screen": "╭─── Claude Code v2.1.233 ─────────────────────────────────────────────────────────────────────────╮\n│                                                    │ Tips for getting started                    │\n│                 Welcome back Asad!                 │ Run /init to create a CLAUDE.md file with … │\n│                                                    │ ─────────────────────────────────────────── │\n│                       ▐▛███▜▌                      │ What's new                                  │\n│                      ▝▜█████▛▘                     │ Added GitLab merge request URL support to … │\n│                        ▘▘ ▝▝                       │ Added an opt-in `forward_user_identity` ap… │\n│   Opus 5 (1M context) with xhig… · Claude Max ·    │ Added opt-in memory cgroup support for Bas… │\n│   examplemail@gmail.com's Organization             │ /release-notes for more                     │\n│                    C:\\td-build                     │                                             │\n╰──────────────────────────────────────────────────────────────────────────────────────────────────╯\n\n\n❯ /model \n  ⎿  Kept model as Opus 5 (1M context) (default)\n\n────────────────────────────────────────────────────────────────────────────────────────────────────\n❯ \n────────────────────────────────────────────────────────────────────────────────────────────────────\n  ⏵⏵ don't ask on (shift+tab to cycle) · ← for agents                 Ctrl+Y to paste deleted text  \n\n\n\n\n\n\n\n\n\n"
        }
      ]
    },
    "withoutTerm": {
      "env": "the same spawn with TERM unset",
      "pointer": ">",
      "shots": [
        {
          "label": "idle-after-boot",
          "screen": "╭─── Claude Code v2.1.233 ─────────────────────────────────────────────────────────────────────────╮\n│                                                    │ Tips for getting started                    │\n│                 Welcome back Asad!                 │ Run /init to create a CLAUDE.md file with … │\n│                                                    │ ─────────────────────────────────────────── │\n│                       ▐▛███▜▌                      │ What's new                                  │\n│                      ▝▜█████▛▘                     │ Added GitLab merge request URL support to … │\n│                        ▘▘ ▝▝                       │ Added an opt-in `forward_user_identity` ap… │\n│   Opus 5 (1M context) with xhig… · Claude Max ·    │ Added opt-in memory cgroup support for Bas… │\n│   examplemail@gmail.com's Organization             │ /release-notes for more                     │\n│                    C:\\td-build                     │                                             │\n╰──────────────────────────────────────────────────────────────────────────────────────────────────╯\n\n\n────────────────────────────────────────────────────────────────────────────────────────────────────\n> \n────────────────────────────────────────────────────────────────────────────────────────────────────\n  ⏵⏵ don't ask on (shift+tab to cycle) · ← for agents\n\n\n\n\n\n\n\n\n\n\n\n\n"
        },
        {
          "label": "typed-slash-model",
          "screen": "│                 Welcome back Asad!                 │ Run /init to create a CLAUDE.md file with … │\n│                                                    │ ─────────────────────────────────────────── │\n│                       ▐▛███▜▌                      │ What's new                                  │\n│                      ▝▜█████▛▘                     │ Added GitLab merge request URL support to … │\n│                        ▘▘ ▝▝                       │ Added an opt-in `forward_user_identity` ap… │\n│   Opus 5 (1M context) with xhig… · Claude Max ·    │ Added opt-in memory cgroup support for Bas… │\n│   examplemail@gmail.com's Organization             │ /release-notes for more                     │\n│                    C:\\td-build                     │                                             │\n╰──────────────────────────────────────────────────────────────────────────────────────────────────╯\n\n\n────────────────────────────────────────────────────────────────────────────────────────────────────\n> /model\n────────────────────────────────────────────────────────────────────────────────────────────────────\n/model                        Set the AI model for Claude Code (currently Opus 5 (1M context))\n/claude-api                   Reference for the Claude API / Anthropic SDK — model ids, pricing,\n                              params, streaming, tool use, MCP, agents, caching, token counting…\n/loop                         Run a prompt or slash command on a recurring interval (e.g. /loop\n                              5m /foo). Omit the interval to let the model self-pace.\n/advisor                      Let Claude consult a stronger model at key moments\n/effort                       Set effort level for model usage\n/status                       Show Claude Code status including version, model, account, API\n                              connectivity, and tool statuses\n/auto-mode-setup              Set up and customise auto mode — environment context, plus\n                              optional rule tweaks\n/doctor                       Health-check the user's Claude Code setup and fix issues: diagnose\n                              installation health — what the `claude doctor` terminal diagnosti…\n/update-config                Use this skill to configure the Claude Code harness via\n                              settings.json. Automated behaviors (\"from now on when X\", \"each t…    \n"
        },
        {
          "label": "model-picker-open",
          "screen": "╭─── Claude Code v2.1.233 ─────────────────────────────────────────────────────────────────────────╮\n│                                                    │ Tips for getting started                    │\n│                 Welcome back Asad!                 │ Run /init to create a CLAUDE.md file with … │\n│                                                    │ ─────────────────────────────────────────── │\n│                       ▐▛███▜▌                      │ What's new                                  │\n│                      ▝▜█████▛▘                     │ Added GitLab merge request URL support to … │\n│                        ▘▘ ▝▝                       │ Added an opt-in `forward_user_identity` ap… │\n│   Opus 5 (1M context) with xhig… · Claude Max ·    │ Added opt-in memory cgroup support for Bas… │\n│   examplemail@gmail.com's Organization             │ /release-notes for more                     │\n│                    C:\\td-build                     │                                             │\n╰──────────────────────────────────────────────────────────────────────────────────────────────────╯\n\n\n> /model\n\n────────────────────────────────────────────────────────────────────────────────────────────────────\n  Select model\n  Switch between Claude models. Your pick becomes the default for new sessions. For other/previous  \n  model names, specify with --model.\n\n  > 1. Default (recommended) √  Opus 5 with 1M context · Best for everyday, complex tasks\n    2. Opus (1M context)        Opus 5 with 1M context · Best for everyday, complex tasks\n    3. Fable                    Fable 5 · Most capable for your hardest and longest-running tasks   \n    4. Sonnet                   Sonnet 5 · Efficient for routine tasks\n    5. Haiku                    Haiku 4.5 · Fastest for quick answers\n\n  ◉ xHigh effort ←/→ to adjust\n\n  Enter to set as default · s to use this session only · Esc to cancel\n"
        },
        {
          "label": "after-escape",
          "screen": "╭─── Claude Code v2.1.233 ─────────────────────────────────────────────────────────────────────────╮\n│                                                    │ Tips for getting started                    │\n│                 Welcome back Asad!                 │ Run /init to create a CLAUDE.md file with … │\n│                                                    │ ─────────────────────────────────────────── │\n│                       ▐▛███▜▌                      │ What's new                                  │\n│                      ▝▜█████▛▘                     │ Added GitLab merge request URL support to … │\n│                        ▘▘ ▝▝                       │ Added an opt-in `forward_user_identity` ap… │\n│   Opus 5 (1M context) with xhig… · Claude Max ·    │ Added opt-in memory cgroup support for Bas… │\n│   examplemail@gmail.com's Organization             │ /release-notes for more                     │\n│                    C:\\td-build                     │                                             │\n╰──────────────────────────────────────────────────────────────────────────────────────────────────╯\n\n\n> /model\n  ⎿  Kept model as Opus 5 (1M context) (default)\n\n────────────────────────────────────────────────────────────────────────────────────────────────────\n> \n────────────────────────────────────────────────────────────────────────────────────────────────────\n  ⏵⏵ don't ask on (shift+tab to cycle) · ← for agents                            ◉ xhigh · /effort\n\n\n\n\n\n\n\n\n\n"
        },
        {
          "label": "typed-slash-effort",
          "screen": "│                      ▝▜█████▛▘                     │ Added GitLab merge request URL support to … │\n│                        ▘▘ ▝▝                       │ Added an opt-in `forward_user_identity` ap… │\n│   Opus 5 (1M context) with xhig… · Claude Max ·    │ Added opt-in memory cgroup support for Bas… │\n│   examplemail@gmail.com's Organization             │ /release-notes for more                     │\n│                    C:\\td-build                     │                                             │\n╰──────────────────────────────────────────────────────────────────────────────────────────────────╯\n\n\n> /model\n  ⎿  Kept model as Opus 5 (1M context) (default)\n\n────────────────────────────────────────────────────────────────────────────────────────────────────\n> /effort\n────────────────────────────────────────────────────────────────────────────────────────────────────\n/effort                       Set effort level for model usage\n/code-review                  3 free /ultrareview · Review the current diff, or a PR\n                              number/branch/path target, for correctness bugs and reuse/simplif…\n\n\n\n\n\n\n\n\n\n\n\n\n"
        },
        {
          "label": "after-ctrl-u",
          "screen": "╭─── Claude Code v2.1.233 ─────────────────────────────────────────────────────────────────────────╮\n│                                                    │ Tips for getting started                    │\n│                 Welcome back Asad!                 │ Run /init to create a CLAUDE.md file with … │\n│                                                    │ ─────────────────────────────────────────── │\n│                       ▐▛███▜▌                      │ What's new                                  │\n│                      ▝▜█████▛▘                     │ Added GitLab merge request URL support to … │\n│                        ▘▘ ▝▝                       │ Added an opt-in `forward_user_identity` ap… │\n│   Opus 5 (1M context) with xhig… · Claude Max ·    │ Added opt-in memory cgroup support for Bas… │\n│   examplemail@gmail.com's Organization             │ /release-notes for more                     │\n│                    C:\\td-build                     │                                             │\n╰──────────────────────────────────────────────────────────────────────────────────────────────────╯\n\n\n> /model \n  ⎿  Kept model as Opus 5 (1M context) (default)\n\n────────────────────────────────────────────────────────────────────────────────────────────────────\n> \n────────────────────────────────────────────────────────────────────────────────────────────────────\n  ⏵⏵ don't ask on (shift+tab to cycle) · ← for agents                 Ctrl+Y to paste deleted text  \n\n\n\n\n\n\n\n\n\n"
        }
      ]
    }
  }
}

"""###
}
