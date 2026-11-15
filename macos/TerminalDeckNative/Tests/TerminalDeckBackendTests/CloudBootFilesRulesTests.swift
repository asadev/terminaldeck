import Foundation
import Testing
import TerminalDeckNativeCore

@Suite("Cloud boot files: the list and the decision")
struct CloudBootFilesRulesTests {
    typealias Rules = CloudBootFilesRules

    @Test func theseAreBootFiles() {
        let allowed: [(CloudBootFilesPlaceKind, String)] = [
            (.project, "CLAUDE.md"), (.project, "AGENTS.md"), (.project, "GEMINI.md"),
            (.project, ".claude/agents/reviewer.md"), (.project, ".claude/skills/review/SKILL.md"), (.project, ".claude/skills/review/scripts/run.sh"),
            (.project, ".claude/commands/ship.md"), (.project, ".claude/commands/team/ship.md"), (.project, ".agents/skills/x/SKILL.md"),
            (.project, ".codex/skills/y/SKILL.md"), (.project, ".gemini/skills/z/SKILL.md"), (.project, ".claude/skills/caf\u{e9}/SKILL.md"),
            (.claude, "CLAUDE.md"), (.claude, "agents/a.md"), (.claude, "skills/s/SKILL.md"), (.claude, "commands/c.md"),
            (.codex, "AGENTS.md"), (.codex, "skills/s/SKILL.md"), (.gemini, "GEMINI.md"), (.gemini, "skills/s/SKILL.md"), (.agents, "skills/s/SKILL.md")
        ]
        for (kind, path) in allowed {
            let refusal = Rules.refusal(kind: kind, relative: path)
            #expect(refusal == nil, "\(kind.rawValue) \(path)")
        }
    }

    @Test func nothingElseIsABootFile() {
        let refused: [(CloudBootFilesPlaceKind, String, CloudBootFilesRefusal)] = [
            // Not on the list (letter case counts for the listed names).
            (.project, "claude.md", .notListed), (.project, "src/CLAUDE.md", .notListed), (.project, "README.md", .notListed),
            (.project, ".claude/settings.json", .notListed), (.project, ".claude/settings.local.json", .notListed), (.project, ".mcp.json", .notListed),
            (.project, ".Claude/skills/x/SKILL.md", .notListed), (.project, ".claude/skills", .notListed), (.project, ".claude/agent-memory/r/MEMORY.md", .notListed),
            (.codex, "CLAUDE.md", .notListed),
            // A provider's own memory, conversations, settings and sign-in.
            (.claude, "projects/-Users-x-app/memory/MEMORY.md", .notListed), (.claude, "projects/-Users-x-app/chat.jsonl", .notListed),
            (.claude, "settings.json", .notListed), (.claude, ".credentials.json", .notListed), (.claude, "history.jsonl", .notListed),
            (.codex, "memories/m.md", .notListed), (.codex, "sessions/2026/s.jsonl", .notListed), (.codex, "auth.json", .notListed), (.codex, "config.toml", .notListed),
            (.gemini, "tmp/abc/chats/session-1.json", .notListed), (.gemini, "settings.json", .notListed), (.gemini, "oauth_creds.json", .notListed),
            // Settings, hooks, MCP and sign-in files inside a listed folder.
            (.project, ".claude/skills/x/settings.json", .never), (.project, ".claude/skills/x/Settings.JSON", .never), (.project, ".claude/skills/x/settings.local.json", .never),
            (.project, ".claude/skills/x/hooks/pre.sh", .never), (.project, ".claude/agents/hooks.json", .never), (.project, ".claude/skills/x/mcp.json", .never),
            (.project, ".claude/skills/x/config.toml", .never), (.project, ".claude/skills/x/server.pem", .never), (.project, ".claude/skills/x/aws-credentials.md", .never),
            (.project, ".claude/skills/x/id_rsa", .never), (.project, ".claude/skills/x/run.lock", .never),
            // Hidden names and installed packages.
            (.project, ".claude/skills/x/.env", .hidden), (.project, ".claude/skills/x/.mcp.json", .hidden), (.codex, "skills/.system/own/SKILL.md", .hidden),
            (.project, ".claude/skills/x/.terminaldeck-copy", .hidden), (.project, ".claude/skills/x/node_modules/p/readme.md", .rebuildable),
            // Not one plain path inside the folder.
            (.project, ".claude/skills/../../outside.md", .path), (.project, "../outside.md", .path), (.project, "/etc/passwd", .path),
            (.project, ".claude/skills//x.md", .path), (.project, ".claude/skills/x/./y.md", .path), (.project, ".claude\\skills\\x.md", .path),
            (.project, ".claude/skills/x/a\u{0}b.md", .path), (.project, ".claude/skills/x/a\u{202e}b.md", .path), (.project, ".claude/skills/x/a\nb.md", .path),
            (.project, ".claude/skills/cafe\u{301}/SKILL.md", .path), (.project, ".claude/skills/\u{301}x/SKILL.md", .path), (.project, "", .path),
            (.project, ".claude/skills/x/", .path)
        ]
        for (kind, path, why) in refused {
            let refusal = Rules.refusal(kind: kind, relative: path)
            #expect(refusal == why, "\(kind.rawValue) \(path.debugDescription)")
        }
    }

    @Test func commonSecretFileNamesNeverTravelWhateverTheirCase() {
        let names = ["token.json", "Token.JSON", "secrets.yaml", "secrets.yml", "SECRETS.json", "prod.env", "staging.ENV", "prod.env.local",
                     "apikey.txt", "api_key.md", "api-key.txt", "service-account-prod.json", "service_account.json", "password.txt",
                     "server.pem", "tls.KEY", "AuthKey_X.p8", "release.jks", "a.keystore", "putty.ppk",
                     "id_rsa", "id_ed25519.pub", "ID_ECDSA", "id_custom", "my-private-key.md", "github-token.md"]
        for name in names {
            let refusal = Rules.refusal(kind: .project, relative: ".claude/skills/x/" + name)
            #expect(refusal == .never, "\(name)")
        }
        // Ordinary skill files still travel.
        for name in ["SKILL.md", "reference.md", "env-setup.md", "keys-and-values.md", "identity.md"] {
            let refusal = Rules.refusal(kind: .project, relative: ".claude/skills/x/" + name)
            #expect(refusal == nil, "\(name)")
        }
    }

    @Test func aPathIsSplitAtSlashBytesNotAtCharacters() {
        // A combining mark after a slash makes one character of the two: Swift would see one name, the disk two.
        #expect(Rules.parts("a/\u{301}b") == nil)
        #expect(Rules.parts("a/b/c") == ["a", "b", "c"])
        #expect(Rules.cleanRelative("a/b") && !Rules.cleanRelative("a/\u{301}b"))
    }

    @Test func onlyTextIsABootFile() {
        #expect(Rules.isText(Data("plain \u{e9}\n".utf8)))
        #expect(Rules.isText(Data()))
        #expect(!Rules.isText(Data([0x41, 0x00, 0x42])))
        #expect(!Rules.isText(Data([0xff, 0xfe, 0x41])))
    }

    @Test func aVersionFromCloudReplacesOnlyWhatThisMacLastSaw() {
        func step(_ local: String?, _ copy: String?, _ base: String?, runs: Bool = false, accepted: Bool = false) -> CloudBootFilesStep {
            Rules.step(local: local, copy: copy, base: base, runs: runs, accepted: accepted)
        }
        #expect(step(nil, nil, nil) == .nothing)
        #expect(step("a", "a", nil) == .nothing)               // identical bytes: already present
        #expect(step("a", nil, nil) == .captureLocal)          // a new file here
        #expect(step("b", "a", "a") == .captureLocal)          // an edit here
        #expect(step(nil, "a", "a") == .captureRemoval)        // removed here
        #expect(step(nil, "x", nil) == .write)                 // arrived, nothing here
        #expect(step("a", "x", "a") == .write)                 // arrived, this Mac's file is what it last saw
        #expect(step("b", "x", "a") == .keepBoth)              // arrived, but edited here since
        #expect(step("b", "x", nil) == .keepBoth)              // arrived, and this Mac has a file of its own
        #expect(step(nil, "x", "a") == .keepBoth)              // arrived, but removed here since
        #expect(step(nil, "x", nil, runs: true) == .needsAccept)
        #expect(step("a", "x", "a", runs: true) == .needsAccept)
        #expect(step("a", "x", "a", runs: true, accepted: true) == .write)
        #expect(step("b", "x", "a", runs: true, accepted: true) == .keepBoth)   // an earlier accept never overrides an edit
    }
}
