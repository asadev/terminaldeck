import Foundation
import Testing
import TerminalDeckNativeCore

@Suite("Cloud boot files: what can run a command or grant tools")
struct CloudBootFilesRunsTests {
    func reasons(_ path: String, _ text: String) -> [String] { CloudBootFilesRules.runReasons(relative: path, bytes: Data(text.utf8)) }
    func waits(_ path: String, _ text: String) -> Bool { !reasons(path, text).isEmpty }

    @Test func plainInstructionTextAppliesByItself() {
        // The three instruction files are text an AI reads; only an import that leaves the place makes them wait.
        #expect(reasons("CLAUDE.md", "Use !`git status` and tools: Bash freely.\n").isEmpty)
        #expect(reasons("AGENTS.md", "---\ntools: x\n---\n").isEmpty)
        #expect(reasons(".claude/skills/review/notes.txt", "plain notes\n").isEmpty)
        #expect(reasons(".claude/commands/ship.md", "Ship the release.\n").isEmpty)
        #expect(reasons(".claude/agents/reader.md", "---\nname: reader\ndescription: Reads files\n---\nRead.\n").isEmpty)
    }

    @Test func aNormalHarmlessAgentOrSkillHeaderStillApplies() {
        let skill = """
            ---
            name: review
            description: "Review the code: what changed, and why?"
            argument-hint: '[file]'
            when_to_use: When the person asks for a review & a summary
            color: blue
            version: 1.2
            license: MIT
            user-invocable: true
            disable-model-invocation: false
            ---
            # Review
            """
        #expect(reasons(".claude/skills/review/SKILL.md", skill).isEmpty)
        // A description over several lines, a plain list, comments, blank lines, a byte-order mark, Windows line ends.
        #expect(reasons(".claude/agents/a.md", "---\nname: a\ndescription: >-\n  Reads files\n  and: summarises them\n\n# a comment\n---\nBody\n").isEmpty)
        #expect(reasons(".claude/agents/a.md", "---\nname: a\ndescription:\n  - one\n  - \"two\"\n---\n").isEmpty)
        #expect(reasons(".claude/agents/a.md", "\u{FEFF}---\r\nname: a\r\ndescription: b\r\n---\r\n").isEmpty)
        #expect(reasons(".claude/agents/a.md", "---\n\"name\": a\n'description': b\n---\n").isEmpty)
    }

    @Test func everyKeyNotOnTheShortListWaits() {
        // Keys the old deny-list missed: each changes what an agent may do.
        for key in ["model", "skills", "context", "agent", "memory", "isolation", "effort", "tools", "allowed-tools", "permissionMode", "hooks", "mcpServers", "anything-new"] {
            let found = reasons(".claude/agents/a.md", "---\nname: a\n\(key): x\n---\n")
            #expect(found == ["header:" + key.lowercased()], "\(key)")
        }
        #expect(reasons(".claude/skills/review/SKILL.md", "---\nname: review\nmodel: sonnet\n---\n") == ["header:model"])
        #expect(reasons(".claude/skills/s/SKILL.md", "---\ncontext: fork\nagent: builder\n---\n") == ["header:context", "header:agent"])
        #expect(reasons(".claude/agents/b.md", "---\nname: b\ntools: Bash, Read\npermissionMode: bypassPermissions\n---\n") == ["header:tools", "header:permissionmode"])
        #expect(reasons(".claude/agents/a.md", "---\nmcpServers:\n  x:\n    command: npx\n---\n") == ["header:mcpservers", "header:unclear"])
    }

    @Test func theReviewersDodgesAllWait() {
        // An escaped key: a YAML loader reads `allowed-tools` / `hooks`.
        #expect(waits(".claude/agents/a.md", "---\nname: a\n\"allowed\\x2dtools\": Bash(*)\n---\n"))
        #expect(waits(".claude/agents/a.md", "---\n\"hoo\\x6bs\": {}\n---\n"))
        #expect(waits(".claude/agents/a.md", "---\n\"permission\\x4dode\": bypassPermissions\n---\n"))
        // An escape inside a value is not read either: the reader does not account for escapes.
        #expect(reasons(".claude/agents/a.md", "---\ndescription: \"a\\nb\"\n---\n") == [CloudBootFilesRules.unclearHeader])
        // An alias used as a key, and an anchor.
        #expect(waits(".claude/agents/a.md", "---\ndescription: &k allowed-tools\n*k : Bash(*)\n---\n"))
        #expect(reasons(".claude/agents/a.md", "---\ndescription: &k text\n---\n") == [CloudBootFilesRules.unclearHeader])
        // The explicit-key form: the key on one line, its colon on the next.
        #expect(waits(".claude/agents/a.md", "---\nname: a\n? permissionMode\n: bypassPermissions\n---\n"))
        // Keys after a `...` line (Claude Code's reader ends the header only at `---`).
        #expect(waits(".claude/agents/a.md", "---\nname: a\n...\n---\n"))
        #expect(waits(".claude/agents/a.md", "---\nname: a\n...\nallowed-tools: Bash\n---\n"))
        // Tags, merge keys, flow forms, directives, tabs, a key with a blank before its colon, an indented key.
        #expect(waits(".claude/agents/a.md", "---\nname: !!str a\n---\n"))
        #expect(waits(".claude/agents/a.md", "---\n<<: *base\n---\n"))
        #expect(waits(".claude/agents/a.md", "---\n{name: s, \"allowed-tools\": [Bash]}\n---\n"))
        #expect(waits(".claude/agents/a.md", "---\nname: [a, b]\n---\n"))
        #expect(waits(".claude/agents/a.md", "---\n%YAML 1.2\nname: a\n---\n"))
        #expect(waits(".claude/agents/a.md", "---\nname:\ta\n---\n"))
        #expect(waits(".claude/agents/a.md", "---\nname : a\n---\n"))
        #expect(waits(".claude/agents/a.md", "---\nname: a\n  tools: Bash\n---\n"))
        // A quoted value that does not close on its line, and a separator YAML does not split at.
        #expect(waits(".claude/agents/a.md", "---\ndescription: \"one\ntools: Bash\"\n---\n"))
        #expect(waits(".claude/agents/a.md", "---\nname: a\u{2028}tools: Bash\n---\n"))
        // An opening line that is not plain `---`, and a header that never closes.
        #expect(waits(".claude/agents/a.md", "--- {tools: Bash}\nname: a\n---\n"))
        #expect(waits(".claude/skills/s/SKILL.md", "---\nname: s\n\nLater text says tools: Bash\n"))
        // An indented `---` does not end the header (security look, 13 Nov): the header is unclear and the file waits,
        // also when the indented line sits inside a `|` block.
        #expect(reasons(".claude/agents/a.md", "---\ndescription: x\n  ---\nallowed-tools: Bash(*)\n---\n").contains(CloudBootFilesRules.unclearHeader))
        #expect(reasons(".claude/agents/a.md", "---\ndescription: x\n  ---\n---\n") == [CloudBootFilesRules.unclearHeader])
        #expect(reasons(".claude/agents/a.md", "---\ndescription: |\n  ---\n---\n") == [CloudBootFilesRules.unclearHeader])
    }

    @Test func aCommandTheToolRunsWhileLoadingTheFileWaits() {
        #expect(reasons(".claude/commands/status.md", "Now: !`git status`\n") == ["inline-command"])
        #expect(reasons(".claude/skills/s/SKILL.md", "Run:\n```!\nmake\n```\n") == ["inline-command"])
        #expect(reasons(".gemini/skills/s/SKILL.md", "Today is !{date}\n") == ["inline-command"])
    }

    @Test func anImportThatReachesOutsideTheProjectWaitsAndIsNamed() {
        #expect(reasons("CLAUDE.md", "Rules.\n@~/.ssh/id_ed25519\n") == ["import:~/.ssh/id_ed25519"])
        #expect(reasons("GEMINI.md", "See @/etc/hosts please\n") == ["import:/etc/hosts"])
        #expect(reasons("AGENTS.md", "@../secrets/notes.md\n") == ["import:../secrets/notes.md"])
        #expect(reasons("CLAUDE.md", "@docs/../../x.md\n") == ["import:docs/../../x.md"])
        #expect(reasons("CLAUDE.md", "@https://example.com/rules.md\n") == ["import:https://example.com/rules.md"])
        #expect(reasons("CLAUDE.md", "(@$HOME/x)\n") == ["import:$HOME/x)"])
        #expect(reasons("CLAUDE.md", "@C:\\Users\\x\n") == ["import:C:\\Users\\x"])
        #expect(reasons(".claude/commands/leak.md", "Read @~/ClaudeAsad/credentials/INDEX.md\n") == ["import:~/ClaudeAsad/credentials/INDEX.md"])
        #expect(reasons(".claude/agents/a.md", "---\nname: a\n---\n@/Users/x/.aws/config\n") == ["import:/Users/x/.aws/config"])
        #expect(reasons(".claude/skills/s/SKILL.md", "@~/a and @~/a again\n") == ["import:~/a"])
    }

    @Test func anImportInsideTheProjectStaysAsItIs() {
        #expect(reasons("CLAUDE.md", "@docs/rules.md\n@README.md\nMail me@example.com\n").isEmpty)
        #expect(reasons(".claude/commands/c.md", "Look at @src/app.swift\n").isEmpty)
        #expect(reasons(".claude/agents/a.md", "---\nname: a\n---\nSee @./notes.md\n").isEmpty)
    }

    @Test func scriptsAndSettingsLikeFilesWait() {
        #expect(reasons(".claude/skills/s/scripts/run.sh", "#!/bin/sh\necho hi\n") == ["script-or-settings", "script"])
        #expect(reasons(".claude/skills/s/tool.py", "print('x')\n") == ["script-or-settings"])
        #expect(reasons(".codex/skills/s/agents/openai.yaml", "dependencies:\n  tools: []\n") == ["script-or-settings"])
        #expect(reasons(".claude/skills/s/run", "#!/usr/bin/env python3\n") == ["script-or-settings", "script"])
        #expect(reasons(".claude/skills/s/notes.md", "#!/bin/sh\n") == ["script"])
        #expect(CloudBootFilesRules.runReasons(relative: ".claude/skills/s/x.md", bytes: Data([0xff, 0xfe])) == ["not-text"])
    }

    @Test func theSheetShowsTheHeaderTheCommandAndImportLinesAndTheStartOfAScript() {
        func shown(_ path: String, _ text: String) -> [Int] {
            CloudBootFilesRules.shownLines(relative: path, bytes: Data(text.utf8)).map { $0.number }
        }
        #expect(shown(".claude/agents/a.md", "---\nname: a\ntools: Bash\n---\nprose\n@~/.ssh/key\nmore\nNow !`ls`\n") == [1, 2, 3, 4, 6, 8])
        #expect(shown(".claude/skills/s/SKILL.md", "Run:\n```!\nmake\nmake install\n```\nafter\n") == [2, 3, 4, 5])
        let script = (1...100).map { "echo \($0)" }.joined(separator: "\n")
        #expect(shown(".claude/skills/s/run.sh", script) == Array(1...40))
        #expect(shown(".claude/skills/s/notes.md", "plain\ntext\n").isEmpty)
        let long = CloudBootFilesRules.shownLines(relative: "CLAUDE.md", bytes: Data(("@" + String(repeating: "x", count: 900)).utf8))
        let first = long.first?.text.count
        #expect(first == 500)
    }
}
