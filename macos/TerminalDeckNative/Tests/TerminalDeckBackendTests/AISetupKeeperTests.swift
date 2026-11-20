import Foundation
import Testing
@testable import TerminalDeckBackend

@Suite("One setup for every AI (skills, rule files, agents, guards) and the project-folder rules")
struct AISetupKeeperTests {
    final class Box: @unchecked Sendable {
        let base: URL
        let bin: URL
        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("td-setup-" + UUID().uuidString, isDirectory: true)
            bin = base.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        }
        var project: URL { base.appendingPathComponent("home/work/app", isDirectory: true) }
        var home: URL { base.appendingPathComponent("home", isDirectory: true) }
        func write(_ path: String, _ text: String, date: Date? = nil) throws {
            let url = project.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            if let date { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
        }
        func text(_ path: String) -> String? { (try? Data(contentsOf: project.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) } }
        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: project.appendingPathComponent(path).path) }
        var discard: BackendAISetupKeeper.Discard {
            let bin = self.bin
            return { url in try FileManager.default.moveItem(at: url, to: bin.appendingPathComponent(UUID().uuidString)) }
        }
        func align() -> [String] { BackendAISetupKeeper.align(project: project, discard: discard) }
        func close() { try? FileManager.default.removeItem(at: base) }
    }

    @Test func theProjectIsTheNearestFolderWithClaudeFilesAndNeverTheHome() throws {
        let b = try Box(); defer { b.close() }
        try b.write("CLAUDE.md", "rules\n")
        try FileManager.default.createDirectory(at: b.project.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b.home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let real = b.project.resolvingSymlinksInPath().path
        #expect(BackendAISetupKeeper.projectRoot(containing: b.project.appendingPathComponent("src/deep").path, home: b.home)?.path == real)
        #expect(BackendAISetupKeeper.projectRoot(containing: b.project.path, home: b.home)?.path == real)
        // The home folder has `.claude` (the AI's own settings): it is never a project.
        #expect(BackendAISetupKeeper.projectRoot(containing: b.home.appendingPathComponent("work").path, home: b.home) == nil)
        #expect(BackendAISetupKeeper.projectRoot(containing: b.home.path, home: b.home) == nil)
    }

    @Test func skillsAreTheSameInEveryFolderAndTheNewestCopyWins() throws {
        let b = try Box(); defer { b.close() }
        let old = Date(timeIntervalSince1970: 1_700_000_000), new = Date(timeIntervalSince1970: 1_800_000_000)
        try b.write("CLAUDE.md", "rules\n")
        try b.write(".claude/skills/only-claude/SKILL.md", "claude skill\n")
        try b.write(".agents/skills/only-codex/SKILL.md", "made in Codex\n")
        try b.write(".claude/skills/both/SKILL.md", "old words\n", date: old)
        try b.write(".agents/skills/both/SKILL.md", "new words\n", date: new)
        try b.write(".agents/skills/both/scripts/run.sh", "#!/bin/sh\necho hi\n", date: new)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: b.project.appendingPathComponent(".agents/skills/both/scripts/run.sh").path)
        let lines = b.align()
        #expect(b.text(".agents/skills/only-claude/SKILL.md") == "claude skill\n")
        #expect(b.text(".claude/skills/only-codex/SKILL.md") == "made in Codex\n")
        #expect(b.text(".claude/skills/both/SKILL.md") == "new words\n")
        #expect(b.text(".claude/skills/both/scripts/run.sh") == "#!/bin/sh\necho hi\n")
        #expect(FileManager.default.isExecutableFile(atPath: b.project.appendingPathComponent(".claude/skills/both/scripts/run.sh").path))
        // The replaced copy is kept (the Trash in the app), never destroyed.
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: b.bin.path)) ?? []).count == 1)
        #expect(lines.filter { $0.contains("skill") }.count == 3)
        // Aligned: a second look changes nothing and says nothing.
        #expect(b.align().isEmpty)
        // No Gemini skills folder is made when the project has none (Gemini reads `.agents/skills`).
        #expect(!b.exists(".gemini/skills"))
    }

    @Test func ruleFilesArePointersAndHisOwnAreNeverTouched() throws {
        let b = try Box(); defer { b.close() }
        try b.write("CLAUDE.md", "rules\n")
        try b.write("AGENTS.md", "my own Codex rules\n")
        _ = b.align()
        #expect(b.text("AGENTS.md") == "my own Codex rules\n")
        let gemini = try #require(b.text("GEMINI.md"))
        #expect(gemini.contains(BackendAISetupKeeper.markerWords) && gemini.contains("@./CLAUDE.md"))
        // Without CLAUDE.md nothing is made.
        let c = try Box(); defer { c.close() }
        try c.write(".claude/agents/x.md", "---\nname: x\n---\nX.\n")
        _ = c.align()
        #expect(!c.exists("AGENTS.md") && !c.exists("GEMINI.md"))
    }

    @Test func everyClaudeAgentGetsItsCodexAndGeminiFormAndHisOwnFileStays() throws {
        let b = try Box(); defer { b.close() }
        try b.write(".claude/agents/0-decker.md", "---\nname: decker\ndescription: \"Lead \\\"quoted\\\" of the team\"\nmodel: opus\n---\n\nYou are Decker.\nSay \"\"\"hi\"\"\" \\ there.\n")
        try b.write(".claude/agents/cloud.md", "---\nname: cloud\ndescription: Cloud seat.\n---\nYou own the Cloud.\n")
        try b.write(".codex/agents/cloud.toml", "name = \"cloud\"\ndescription = \"his own\"\ndeveloper_instructions = \"\"\"\nmine\"\"\"\n")
        _ = b.align()
        let toml = try #require(b.text(".codex/agents/0-decker.toml"))
        #expect(toml.hasPrefix("# " + BackendAISetupKeeper.markerWords))
        #expect(toml.contains("name = \"decker\"") && toml.contains("developer_instructions = \"\"\"\nYou are Decker."))
        #expect(!toml.contains("\"\"\"hi"))
        #expect(b.text(".codex/agents/cloud.toml")?.contains("his own") == true)
        let gemini = try #require(b.text(".gemini/agents/0-decker.md"))
        #expect(gemini.hasPrefix("---\n# " + BackendAISetupKeeper.markerWords) && gemini.contains("\nname: decker\n") && gemini.contains("You are Decker."))
        #expect(!gemini.contains("model:"))
        #expect(b.text(".gemini/agents/cloud.md")?.contains("You own the Cloud.") == true)
        // Same input, same bytes: a second look writes nothing.
        #expect(b.align().isEmpty)
        // An agent removed from .claude/agents: the app's copies go, his own file stays.
        try FileManager.default.removeItem(at: b.project.appendingPathComponent(".claude/agents/cloud.md"))
        _ = b.align()
        #expect(!b.exists(".gemini/agents/cloud.md"))
        #expect(b.text(".codex/agents/cloud.toml")?.contains("his own") == true)
    }

    @Test func claudesGuardsBecomeCodexAndGeminiGuardsBesideHisOwnEntries() throws {
        let b = try Box(); defer { b.close() }
        try b.write(".claude/settings.json", """
            {"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "python3 \\"$CLAUDE_PROJECT_DIR/.claude/hooks/never-commands.py\\"", "timeout": 5}]}],
             "SubagentStop": [{"hooks": [{"type": "command", "command": "echo done"}]}]}}
            """)
        try b.write(".codex/hooks.json", #"{"hooks": {"PermissionRequest": [{"matcher": "*", "hooks": [{"type": "command", "command": "/his/own.py", "timeout": 10}]}]}}"#)
        try b.write(".gemini/settings.json", #"{"theme": "Dark"}"#)
        let result = BackendAISetupKeeper.alignGuards(b.project)
        #expect(result.noEquivalent == ["Gemini: SubagentStop"])
        let codex = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: b.project.appendingPathComponent(".codex/hooks.json"))) as? [String: Any])
        let codexHooks = try #require(codex["hooks"] as? [String: Any])
        #expect((codexHooks["PermissionRequest"] as? [Any])?.count == 1)
        let pre = try #require((codexHooks["PreToolUse"] as? [[String: Any]])?.first)
        #expect(pre["matcher"] as? String == "Bash|shell|local_shell|exec_command")
        let codexHandler = try #require((pre["hooks"] as? [[String: Any]])?.first)
        let codexCommand = try #require(codexHandler["command"] as? String)
        #expect(codexCommand.contains("export CLAUDE_PROJECT_DIR=") && codexCommand.contains("never-commands.py") && codexCommand.contains("\"tool_name\":\"Bash\""))
        #expect(!codexCommand.contains(b.base.path))
        #expect(codexHandler["timeout"] as? Int == 5 && codexHandler["statusMessage"] as? String == BackendAISetupKeeper.hookMarker)
        #expect(codexHooks["SubagentStop"] != nil)
        let gemini = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: b.project.appendingPathComponent(".gemini/settings.json"))) as? [String: Any])
        #expect(gemini["theme"] as? String == "Dark")
        let before = try #require(((gemini["hooks"] as? [String: Any])?["BeforeTool"] as? [[String: Any]])?.first)
        #expect(before["matcher"] as? String == "run_shell_command")
        let geminiHandler = try #require((before["hooks"] as? [[String: Any]])?.first)
        #expect(geminiHandler["timeout"] as? Int == 5000 && geminiHandler["name"] as? String == BackendAISetupKeeper.hookMarker)
        #expect((geminiHandler["command"] as? String)?.contains("run_shell_command\"/\"tool_name\":\"Bash\"") == true)
        // Same input, same bytes: nothing is rewritten. Two Macs make the same files.
        let bytes = try Data(contentsOf: b.project.appendingPathComponent(".codex/hooks.json"))
        #expect(BackendAISetupKeeper.alignGuards(b.project).lines.isEmpty)
        #expect(try Data(contentsOf: b.project.appendingPathComponent(".codex/hooks.json")) == bytes)
        // The guard removed in Claude: the app's entries go, his entry stays.
        try b.write(".claude/settings.json", "{}")
        _ = BackendAISetupKeeper.alignGuards(b.project)
        let after = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: b.project.appendingPathComponent(".codex/hooks.json"))) as? [String: Any])
        #expect((after["hooks"] as? [String: Any])?.keys.sorted() == ["PermissionRequest"])
    }

    @Test func theGeminiTranslatorTellsAClaudeGuardWhatClaudeWould() throws {
        // The wrapped command really runs: Gemini's input reaches the guard in Claude's words.
        let wrapped = BackendAISetupKeeper.wrap("cat", translate: BackendAISetupKeeper.translator([("run_shell_command", "Bash")], field: "tool_name")
            + BackendAISetupKeeper.translator([("BeforeTool", "PreToolUse")], field: "hook_event_name"), findProject: false)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", wrapped]
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"hook_event_name": "BeforeTool", "tool_name": "run_shell_command", "tool_input": {"command": "ls"}}"#.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let seen = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(seen.contains(#""tool_name":"Bash""#) && seen.contains(#""hook_event_name":"PreToolUse""#) && seen.contains(#""command": "ls""#))
        #expect(process.terminationStatus == 0)
    }

    @Test func projectFolderRulesTakeEveryFolderAndKeepOutOnlyRebuiltThings() throws {
        let b = try Box(); defer { b.close() }
        for folder in ["team", "notes", "logs", "backups", "code", "installers", "node_modules", ".claude"] {
            try FileManager.default.createDirectory(at: b.project.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        // A folder that is a code checkout (it holds .git) never travels.
        try FileManager.default.createDirectory(at: b.project.appendingPathComponent("vendor/.git"), withIntermediateDirectories: true)
        #expect(CloudProjectFoldersRules.folders(projectRoot: b.project) == ["backups", "logs", "notes", "team"])
        try b.write(CloudProjectFoldersRules.listFile, "team\ncode\n../x\n# a note\n")
        #expect(CloudProjectFoldersRules.folders(projectRoot: b.project) == ["team"])
        let key = CloudProjectFoldersRules.key(projectId: "project-1")
        #expect(key == CloudProjectFoldersRules.key(projectId: "project-1") && key != CloudProjectFoldersRules.key(projectId: "project-2") && key.count == 17)
        // Every kind of file travels, secret-looking names and hidden files included.
        for path in ["team/cloud/card.md", "notes/shot.png", "notes/clip.mov", "notes/app.zip", "notes/.env", "notes/x/id_rsa", "logs/.hidden/run.log"] {
            #expect(CloudProjectFoldersRules.refusal(key + "/" + path) == nil, "\(path)")
        }
        #expect(CloudProjectFoldersRules.refusal(key + "/notes/app/node_modules/p/a.md") == .rebuildable)
        #expect(CloudProjectFoldersRules.refusal(key + "/notes/src/.git/config") == .rebuildable)
        #expect(CloudProjectFoldersRules.refusal(key + "/notes/.DS_Store") == .temporary)
        #expect(CloudProjectFoldersRules.refusal(key + "/notes/._shot.png") == .temporary)
        #expect(CloudProjectFoldersRules.refusal(key + "/.claude/settings.json") == .hidden)
        #expect(CloudProjectFoldersRules.refusal("notes/card.md") == .name)
        #expect(CloudProjectFoldersRules.refusal(key + "/card.md") == .name)
        // On unless someone switched it off.
        #expect(CloudProjectFoldersRules.isOn(UserDefaults(suiteName: "td-setup-" + UUID().uuidString)!))
    }
}
