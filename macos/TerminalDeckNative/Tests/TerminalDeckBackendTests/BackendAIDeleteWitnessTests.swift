import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// The AI delete witness: real-shaped hook payloads for Claude Code, Codex and Gemini, the time-overlap rule,
/// the link rule, a hand delete during an unrelated AI command, a restart mid-command and a background command.
@Suite("AI delete witness")
struct BackendAIDeleteWitnessTests {
    let home = "/Users/a"
    let project = "/Users/a/Projects/site"
    let t0 = Date(timeIntervalSince1970: 1_794_000_000)
    let row = NativeRPCValue.object([.init("id", .string("td-1")), .init("agent", .string("Builder")), .init("title", .string("site"))])

    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    func event(_ provider: String, _ name: String, _ body: [String: Any], session: String = "td-1") -> BackendSessionHookEvent {
        BackendSessionHookEvent.parse(provider: provider, event: name, sessionID: session,
            body: try! JSONSerialization.data(withJSONObject: body), environmentHeader: nil, peerPID: 1)
    }
    func claude(_ name: String, tool: String = "Bash", input: [String: Any], id: String = "toolu_01") -> BackendSessionHookEvent {
        event("claude", name, ["session_id": "9b2c", "transcript_path": "/x.jsonl", "cwd": project, "permission_mode": "default",
                               "hook_event_name": name, "tool_name": tool, "tool_input": input, "tool_use_id": id])
    }
    func witness(_ dir: URL? = nil, start: Double = -600) -> BackendAIDeleteWitness {
        BackendAIDeleteWitness(dataRoot: dir, home: home, now: at(start))
    }
    func verdict(_ w: BackendAIDeleteWitness, _ path: String, _ from: Double, _ to: Double, now: Double = 1_000) -> BackendAIDeleteVerdict {
        w.verdict(path: path, lastSeen: at(from), goneAt: at(to), now: at(now))
    }

    // MARK: Each AI

    @Test func claudeBashRemovesFolderTree() {
        let w = witness()
        w.accept(claude("PreToolUse", input: ["command": "rm -rf build", "description": "Clean"]), session: row, at: at(0))
        w.accept(claude("PostToolUse", input: ["command": "rm -rf build", "description": "Clean"]), session: row, at: at(1))
        #expect(verdict(w, project + "/build/app.js", -5, 3) == .byAI(session: "td-1", agentName: "Builder", since: at(0)))
        #expect(verdict(w, project + "/build", -5, 3).removedEverywhere)
        #expect(verdict(w, project + "/src/app.js", -5, 3) == .byHand)
    }

    @Test func codexArgvCommandWithCdAndToolUseID() {
        let w = witness()
        let input: [String: Any] = ["command": ["bash", "-lc", "cd src && rm old.txt"]]
        let base: [String: Any] = ["session_id": "019a", "cwd": project, "model": "gpt-5", "turn_id": "1", "tool_name": "Bash", "tool_use_id": "call_7", "tool_input": input]
        w.accept(event("codex", "PreToolUse", base.merging(["hook_event_name": "PreToolUse"]) { $1 }), session: nil, at: at(0))
        w.accept(event("codex", "PostToolUse", base.merging(["hook_event_name": "PostToolUse"]) { $1 }), session: nil, at: at(2))
        #expect(verdict(w, project + "/src/old.txt", 1, 4) == .byAI(session: "td-1", agentName: "Codex", since: at(0)))
        #expect(verdict(w, project + "/src/other.txt", 1, 4) == .byHand)
        #expect(verdict(w, project + "/old.txt", 1, 4) == .byHand)
    }

    @Test func geminiGlobInDirectoryPairsWithoutID() {
        let w = witness()
        let body: [String: Any] = ["session_id": "g-1", "cwd": project, "timestamp": "2026-11-14T20:00:00Z", "tool_name": "run_shell_command",
                                   "tool_input": ["command": "rm *.log", "dir_path": "logs", "description": "tidy"]]
        w.accept(event("gemini", "BeforeTool", body), session: row, at: at(0))
        w.accept(event("gemini", "AfterTool", body), session: row, at: at(1))
        #expect(verdict(w, project + "/logs/a.log", 0, 2).removedEverywhere)
        #expect(verdict(w, project + "/logs/a.txt", 0, 2) == .byHand)
        // Not recursive: a .log one folder deeper is not named by `rm *.log`.
        #expect(verdict(w, project + "/logs/old/b.log", 0, 2) == .byHand)
    }

    @Test func patchDeleteAndMoveNameTheExactPath() {
        let w = witness()

        let patch = "*** Begin Patch\n*** Delete File: docs/old.md\n*** Update File: a.txt\n*** Move to: b.txt\n@@\n-x\n+y\n*** End Patch"
        let body: [String: Any] = ["session_id": "019a", "cwd": project, "tool_name": "apply_patch", "tool_use_id": "call_p", "tool_input": ["command": patch]]
        w.accept(event("codex", "PreToolUse", body), session: nil, at: at(10))
        w.accept(event("codex", "PostToolUse", body), session: nil, at: at(10.5))
        #expect(verdict(w, project + "/docs/old.md", 9, 11).removedEverywhere)
        #expect(verdict(w, project + "/a.txt", 9, 11).removedEverywhere)
        #expect(verdict(w, project + "/b.txt", 9, 11) == .byHand)
    }

    // MARK: Rules

    @Test func overlapNeedsTheSpanWithinTwoSeconds() {
        let w = witness()
        w.accept(claude("PreToolUse", input: ["command": "rm notes.md"]), session: row, at: at(100))
        w.accept(claude("PostToolUse", input: ["command": "rm notes.md"]), session: row, at: at(101))
        let path = project + "/notes.md"
        #expect(verdict(w, path, 90, 98.5).removedEverywhere)     // ends 1.5 s before the start: within tolerance
        #expect(verdict(w, path, 90, 97) == .byHand)              // ends 3 s before
        #expect(verdict(w, path, 102.5, 110).removedEverywhere)   // last seen 1.5 s after the end
        #expect(verdict(w, path, 104, 110) == .byHand)            // last seen 3 s after the end: it was still there
    }

    @Test func handDeleteDuringUnrelatedAICommandIsByHand() {
        let w = witness()
        w.accept(claude("PreToolUse", input: ["command": "rm -rf /Users/a/Other/tmp && npm test"]), session: row, at: at(0))
        w.accept(claude("PreToolUse", input: ["command": "ls -la && cat notes.md"], id: "toolu_02"), session: row, at: at(0))
        // He deletes a file in Finder in the same seconds: the commands neither name it nor ran above it with hidden targets.
        #expect(verdict(w, project + "/notes.md", 1, 5) == .byHand)
        #expect(verdict(w, "/Users/a/Other/tmp/x", 1, 5).removedEverywhere)
    }

    @Test func hiddenTargetsFallBackToTheWorkingFolder() {
        let w = witness()
        w.accept(claude("PreToolUse", input: ["command": "rm -rf \"$DIR\""]), session: row, at: at(0))
        #expect(verdict(w, project + "/dist/a.js", 0, 1) == .byAI(session: "td-1", agentName: "Builder", since: at(0)))
        #expect(verdict(w, "/Users/a/Elsewhere/a.js", 0, 1) == .byHand)
        // A dry run removes nothing; a variable in `cd` makes the folder unknown, so nothing is claimed.
        let other = witness()
        other.accept(claude("PreToolUse", input: ["command": "git clean -n"]), session: row, at: at(0))
        other.accept(claude("PreToolUse", input: ["command": "cd \"$DIR\" && rm -rf *"], id: "toolu_04"), session: row, at: at(0))
        #expect(verdict(other, project + "/dist/a.js", 0, 1) == .byHand)
    }

    @Test func linkReadingCases() {
        func covers(_ command: String) -> [BackendAIDeleteWitness.Cover] {
            BackendAIDeleteWitness.shellCovers(command, cwd: project, home: home, depth: 0).covers
        }
        #expect(covers("mv a.txt b.txt") == [.init(kind: .path, value: project + "/a.txt", subtree: true)])
        #expect(covers("git rm --cached a.txt").isEmpty)
        #expect(covers("xargs rm notes/a.md") == [.init(kind: .path, value: project + "/notes/a.md", subtree: false)])
        #expect(covers("npx rimraf notes") == [.init(kind: .path, value: project + "/notes", subtree: true)])
        #expect(covers("echo rm -rf build").isEmpty)
        #expect(covers("rm -f 'my file.txt' > /dev/null 2>&1") == [.init(kind: .path, value: project + "/my file.txt", subtree: false)])
        #expect(covers("find . -name '*.tmp' -delete") == [.init(kind: .path, value: project, subtree: true, name: "*.tmp")])
        #expect(covers("find . -delete") == [.init(kind: .path, value: project, subtree: true)])
        #expect(covers("sudo rm ~/x.txt") == [.init(kind: .path, value: home + "/x.txt", subtree: false)])
        #expect(covers("bash -c 'rm -r cache'") == [.init(kind: .path, value: project + "/cache", subtree: true)])
        #expect(covers("make clean").isEmpty)
        #expect(covers("python3 -c \"import shutil; shutil.rmtree('x')\"").isEmpty)
        #expect(covers("rm $(cat list.txt)") == [.init(kind: .folder, value: project, subtree: true)])
        #expect(covers("cat a.txt | grep x").isEmpty)
    }

    // J-2: side effects owned by git/build tools must never become travelling removals.
    @Test(arguments: ["git checkout other-branch", "git checkout -- CLAUDE.md", "git clean -fdx", "git switch other",
                      "git reset --hard", "git stash", "git rebase main", "git pull", "git merge main",
                      "git restore CLAUDE.md", "git worktree remove ../other", "git rm CLAUDE.md",
                      "git -C /Users/a/Other clean -fdx"])
    func gitRemovalsAreByHand(_ command: String) {
        let w = witness()
        w.accept(claude("PreToolUse", input: ["command": command]), session: row, at: at(0))
        #expect(verdict(w, project + "/CLAUDE.md", 0, 1) == .byHand)
        #expect(verdict(w, "/Users/a/Other/CLAUDE.md", 0, 1) == .byHand)
    }

    @Test(arguments: ["make clean", "npm run clean", "npm run build", "yarn clean", "pnpm run build", "bun run clean",
                      "cargo clean", "gradle clean", "./gradlew build", "xcodebuild clean", "swift build", "swift package clean", "swift build --build-path output.swift"])
    func buildAndCleanRemovalsAreByHand(_ command: String) {
        let w = witness()
        w.accept(claude("PreToolUse", input: ["command": command]), session: row, at: at(0))
        #expect(verdict(w, project + "/CLAUDE.md", 0, 1) == .byHand)
    }

    @Test(arguments: ["python3 -c \"import os; os.remove('CLAUDE.md')\"", "node -e \"require('fs').unlinkSync('CLAUDE.md')\"",
                      "ruby -e \"File.delete('CLAUDE.md')\"", "python cleanup.py", "node cleanup.js", "bash cleanup.sh",
                      "./cleanup.sh", "./cleanup", "/Users/a/bin/cleanup", "swift cleanup.swift", "swift -O cleanup.swift"])
    func inlineCodeAndScriptsCannotBeKnown(_ command: String) {
        let w = witness()
        w.accept(claude("PreToolUse", input: ["command": command]), session: row, at: at(0))
        #expect(verdict(w, project + "/CLAUDE.md", 0, 1) == .cannotKnow)
        #expect(verdict(w, "/Users/a/Other/CLAUDE.md", 0, 1) == .cannotKnow)
    }

    @Test func plainRemovalNamesAFile() {
        let w = witness()
        w.accept(claude("PreToolUse", input: ["command": "rm notes/a.md"]), session: row, at: at(0))
        #expect(verdict(w, project + "/notes/a.md", 0, 1) == .byAI(session: "td-1", agentName: "Builder", since: at(0)))
        #expect(verdict(w, project + "/notes/b.md", 0, 1) == .byHand)
    }

    @Test(arguments: ["xargs rm", "cat list.txt | xargs rm -rf", "$(printf rm) \"$DIR\"", "\"$COMMAND\" \"$DIR\"",
                      "rimraf \"$DIR\"", "npx rimraf \"$DIR\"", "rsync --delete source/ \"$DIR\""])
    func hiddenTargetsOfOtherCommandsNeverUseCwd(_ command: String) {
        let w = witness()
        w.accept(claude("PreToolUse", input: ["command": command]), session: row, at: at(0))
        #expect(verdict(w, project + "/CLAUDE.md", 0, 1) == .byHand)
    }

    @Test(arguments: ["unlink \"$FILE\"", "trash \"$FILE\"", "find \"$DIR\" -delete", "mv \"$FILE\" /tmp/out"])
    func onlyPlainRemovalsMayUseCwd(_ command: String) {
        let w = witness()
        w.accept(claude("PreToolUse", input: ["command": command]), session: row, at: at(0))
        #expect(verdict(w, project + "/notes/a.md", 0, 1).removedEverywhere)
    }

    @Test func scriptsSupplyNoLinkButNamedRemovalsStillCount() {
        let w = witness()
        w.accept(claude("PreToolUse", input: ["command": "rm notes/a.md"]), session: row, at: at(0))
        w.accept(claude("PreToolUse", input: ["command": "python3 cleanup.py"], id: "script"), session: row, at: at(0))
        #expect(verdict(w, project + "/notes/a.md", 0, 1).removedEverywhere)
        #expect(verdict(w, project + "/notes/b.md", 0, 1) == .cannotKnow)
        let hidden = witness()
        hidden.accept(claude("PreToolUse", input: ["command": "rm -rf \"$DIR\" && python3 cleanup.py"]), session: row, at: at(0))
        #expect(verdict(hidden, project + "/notes/a.md", 0, 1) == .cannotKnow)
    }

    // MARK: Restart and background

    @Test func restartMidCommandKeepsTheStart() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aiwitness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = witness(dir)
        before.accept(claude("PreToolUse", input: ["command": "rm -rf build && echo TOKEN-sk-123"]), session: row, at: at(0))
        let saved = try String(contentsOf: dir.appendingPathComponent(BackendAIDeleteWitness.fileName), encoding: .utf8)
        #expect(!saved.contains("TOKEN-sk-123") && !saved.contains("echo"))   // paths only, never the command text

        let after = witness(dir, start: 30)                                    // app restarted 30 s in
        after.accept(claude("PostToolUse", input: ["command": "rm -rf build && echo TOKEN-sk-123"]), session: row, at: at(40))
        #expect(verdict(after, project + "/build/x", 5, 35) == .byAI(session: "td-1", agentName: "Builder", since: at(0)))
        // A hand delete in a span from before this run started, with nothing matching: the witness cannot know.
        #expect(verdict(after, project + "/src/x", 5, 35) == .cannotKnow)
        #expect(verdict(after, project + "/src/x", 50, 60) == .byHand)
    }

    @Test func backgroundCommandOutlivesItsToolCall() {
        let w = witness()
        let input: [String: Any] = ["command": "rm -rf node_modules", "run_in_background": true]
        w.accept(claude("PreToolUse", input: input), session: row, at: at(0))
        w.accept(claude("PostToolUse", input: input), session: row, at: at(0.1))
        w.accept(claude("Stop", input: [:]), session: row, at: at(5))          // the turn ends; the command keeps running
        #expect(verdict(w, project + "/node_modules/x/index.js", 50, 60).removedEverywhere)
        w.accept(claude("SessionEnd", input: [:]), session: row, at: at(120))
        #expect(verdict(w, project + "/node_modules/y/index.js", 200, 300) == .byHand)

        // The same command in the foreground ends with its tool call.
        let fg = witness()
        fg.accept(claude("PreToolUse", input: ["command": "rm -rf node_modules"]), session: row, at: at(0))
        fg.accept(claude("PostToolUse", input: ["command": "rm -rf node_modules"]), session: row, at: at(1))
        #expect(verdict(fg, project + "/node_modules/x/index.js", 50, 60) == .byHand)
        // Shell `&` and nohup count as background too.
        #expect(BackendAIDeleteWitness.shellCovers("nohup rm -rf big &", cwd: project, home: home, depth: 0).background)
    }

    @Test func openWindowWithoutEndIsCappedAndClosedBySessionExit() {
        let w = witness()
        w.accept(claude("PreToolUse", input: ["command": "rm -r out"]), session: row, at: at(0))
        #expect(verdict(w, project + "/out/a", 600, 700, now: 800).removedEverywhere)               // still running
        #expect(verdict(w, project + "/out/a", 4000, 4100, now: 5000) == .byHand)                   // past the 1 h cap
        w.sessionEnded("td-1", at: at(10))
        #expect(verdict(w, project + "/out/a", 600, 700, now: 800) == .byHand)
    }

    // MARK: After the review (15 Nov 2026)

    // Decision 1: tools that never delete never link a path. He deletes the AI's note in Finder a minute later.
    @Test(arguments: [("claude", "Write"), ("claude", "Edit"), ("claude", "MultiEdit"), ("claude", "NotebookEdit"),
                      ("gemini", "write_file"), ("gemini", "replace"), ("codex", "edit_file"), ("codex", "create_file")])
    func writeOrEditThenHandDeleteIsByHand(_ provider: String, _ tool: String) {
        let w = witness()
        let body: [String: Any] = ["session_id": "s", "cwd": project, "tool_name": tool, "tool_use_id": "t1",
                                   "tool_input": ["file_path": project + "/notes/a.md", "path": project + "/notes/a.md", "content": "x"]]
        w.accept(event(provider, provider == "gemini" ? "BeforeTool" : "PreToolUse", body), session: row, at: at(0))
        w.accept(event(provider, provider == "gemini" ? "AfterTool" : "PostToolUse", body), session: row, at: at(0.5))
        #expect(verdict(w, project + "/notes/a.md", -1, 61) == .byHand)
        #expect(BackendAIDeleteWitness.reading(tool: tool, input: .object([.init("file_path", .string(project + "/notes/a.md"))]), cwd: project, home: home) == nil)
    }

    @Test func realDeleteToolAndPatchDeleteLineAreByAI() {
        let w = witness()
        let tool = "mcp__files__delete_file"
        w.accept(claude("PreToolUse", tool: tool, input: ["path": project + "/old.md"], id: "toolu_d"), session: row, at: at(0))
        w.accept(claude("PostToolUse", tool: tool, input: ["path": project + "/old.md"], id: "toolu_d"), session: row, at: at(0.3))
        #expect(verdict(w, project + "/old.md", -1, 1).removedEverywhere)
        let patch = "*** Begin Patch\n*** Delete File: gone.md\n*** Update File: kept.md\n@@\n-x\n+y\n*** End Patch"
        let body: [String: Any] = ["session_id": "019a", "cwd": project, "tool_name": "apply_patch", "tool_use_id": "call_q", "tool_input": ["command": patch]]
        w.accept(event("codex", "PreToolUse", body), session: nil, at: at(10))
        w.accept(event("codex", "PostToolUse", body), session: nil, at: at(10.5))
        #expect(verdict(w, project + "/gone.md", 9, 11).removedEverywhere)
        #expect(verdict(w, project + "/kept.md", 9, 11) == .byHand)   // updated, not removed
    }

    // Decision 2: he empties notes/old in Finder; the AI then removes the empty folder.
    @Test func rmdirAfterHandEmptiedFolderIsByHandForTheFiles() {
        let w = witness()
        w.accept(claude("PreToolUse", input: ["command": "rmdir notes/old"]), session: row, at: at(8))
        w.accept(claude("PostToolUse", input: ["command": "rmdir notes/old"]), session: row, at: at(9))
        #expect(verdict(w, project + "/notes/old/a.md", 0, 10) == .byHand)
        #expect(verdict(w, project + "/notes/old", 0, 10).removedEverywhere)
        let hidden = witness()
        hidden.accept(claude("PreToolUse", input: ["command": "rmdir \"$DIR\""]), session: row, at: at(8))
        #expect(verdict(hidden, project + "/notes/a.md", 0, 10) == .byHand)
        // A wildcard never makes rmdir claim a file he removed by hand just before.
        for command in ["rmdir notes/*", "rmdir */"] {
            #expect(BackendAIDeleteWitness.shellCovers(command, cwd: project, home: home, depth: 0).covers.isEmpty)
            let glob = witness()
            glob.accept(claude("PreToolUse", input: ["command": command]), session: row, at: at(8))
            #expect(verdict(glob, project + "/notes/a.md", 0, 10) == .byHand)
        }
    }

    // Decision 3: a name pattern narrows find -delete to matching entries.
    @Test func findNamePatternDoesNotClaimOtherFiles() {
        let w = witness()
        w.accept(claude("PreToolUse", input: ["command": "find . -name '*.pyc' -delete"]), session: row, at: at(0))
        #expect(verdict(w, project + "/notes.md", 0, 1) == .byHand)
        #expect(verdict(w, project + "/src/x.pyc", 0, 1).removedEverywhere)
        let caseless = witness()
        caseless.accept(claude("PreToolUse", input: ["command": "find ~/Documents -iname .DS_STORE -delete"]), session: row, at: at(0))
        #expect(verdict(caseless, home + "/Documents/a/.DS_Store", 0, 1).removedEverywhere)
        #expect(verdict(caseless, home + "/Documents/a/report.pdf", 0, 1) == .byHand)
        // No pattern, or an OR that could widen it: the folder rule of J-2 stays.
        let plain = witness()
        plain.accept(claude("PreToolUse", input: ["command": "find . -name a -o -name b -delete"]), session: row, at: at(0))
        #expect(verdict(plain, project + "/notes.md", 0, 1).removedEverywhere)
    }

    // Decision 4: refused before it ran, and an end without a start.
    @Test func deniedCommandNeverCounts() {
        let w = witness()
        w.accept(claude("PreToolUse", input: ["command": "rm notes.md"]), session: row, at: at(0))
        w.accept(claude("PermissionRequest", input: ["command": "rm notes.md"]), session: row, at: at(0.1))
        w.accept(claude("Stop", input: [:]), session: row, at: at(20))                 // he said no: no PostToolUse
        #expect(verdict(w, project + "/notes.md", 5, 10) == .byHand)
        // Approved: the end event shows it ran.
        let ok = witness()
        ok.accept(claude("PreToolUse", input: ["command": "rm notes.md"]), session: row, at: at(0))
        ok.accept(claude("PermissionRequest", input: ["command": "rm notes.md"]), session: row, at: at(0.1))
        ok.accept(claude("PostToolUse", input: ["command": "rm notes.md"]), session: row, at: at(3))
        #expect(verdict(ok, project + "/notes.md", 1, 4).removedEverywhere)
        // Gemini asks through a Notification.
        let g = witness()
        let body: [String: Any] = ["session_id": "g", "cwd": project, "tool_name": "run_shell_command", "tool_input": ["command": "rm notes.md"]]
        g.accept(event("gemini", "BeforeTool", body), session: row, at: at(0))
        g.accept(event("gemini", "Notification", ["session_id": "g", "notification_type": "ToolPermission", "message": "x"]), session: row, at: at(0.1))
        g.accept(event("gemini", "AfterAgent", ["session_id": "g"]), session: row, at: at(20))
        #expect(verdict(g, project + "/notes.md", 5, 10) == .byHand)
    }

    @Test func endWithoutStartGivesNoWindow() {
        let w = witness(start: -7200)
        w.accept(claude("PostToolUse", input: ["command": "rm notes.md"]), session: row, at: at(100))
        #expect(verdict(w, project + "/notes.md", 0, 50) == .cannotKnow)              // never "by an AI"
        #expect(verdict(w, project + "/other.md", 0, 50) == .byHand)
    }

    // Decision 5: a working folder that cannot be followed claims nothing through it.
    @Test func unfollowableWorkingFolderClaimsNothing() {
        func covers(_ command: String) -> [BackendAIDeleteWitness.Cover] {
            BackendAIDeleteWitness.shellCovers(command, cwd: project, home: home, depth: 0).covers
        }
        #expect(covers("pushd src && popd && rm a.txt").isEmpty)
        #expect(covers("(cd src && rm a.txt); rm b.txt").isEmpty)
        #expect(covers("{ cd src; }; rm a.txt").isEmpty)
        #expect(covers("cd - && rm a.txt").isEmpty)
        #expect(covers("cd \"$X\" && rm a.txt").isEmpty)
        // A path written out in full still counts.
        #expect(covers("popd; rm /Users/a/x.txt") == [.init(kind: .path, value: "/Users/a/x.txt", subtree: false)])
        let w = witness()
        w.accept(claude("PreToolUse", input: ["command": "pushd src && popd && rm a.txt"]), session: row, at: at(0))
        #expect(verdict(w, project + "/src/a.txt", 0, 1) == .byHand)
        #expect(verdict(w, project + "/a.txt", 0, 1) == .byHand)
    }
}
