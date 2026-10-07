import Foundation
import Darwin
import TerminalDeckNativeCore

public struct BackendReadinessService: Sendable {
    public static let channels: Set<String> = ["readiness:scan", "readiness:fix"]
    public static let fixIDs: Set<String> = ["create-claude-md", "create-agents-md", "create-gemini-md", "create-readme", "create-gitignore", "patch-gitignore", "git-init", "ignore-secrets", "untrack-secrets", "add-test-script", "replace-test-script", "add-typecheck-script", "add-lint-script", "create-lockfile", "upgrade-agent-cli"]
    private let projects: BackendProjectService, git: BackendGitService
    private let tools: BackendReadinessTools
    private let authorizeMutation: @Sendable (NativeRPCContext) throws -> Void
    private let appName: String
    public init(projects: BackendProjectService, git: BackendGitService, tools: BackendReadinessTools, appName: String,
                authorizeMutation: @escaping @Sendable (NativeRPCContext) throws -> Void) {
        self.projects = projects; self.git = git; self.tools = tools; self.appName = appName; self.authorizeMutation = authorizeMutation
    }
    private static let weights: [String: Double] = ["secrets": 30, "claude-md": 18, "test-script": 14, "git-repo": 12, "gitignore": 10, "readme": 8, "typecheck-script": 8, "git-clean": 8, "lint-script": 6, "lockfile": 6]
    private static let agents: [(id: String, file: String, candidates: [String], fix: String)] = [("claude", "CLAUDE.md", ["CLAUDE.md", ".claude/CLAUDE.md", "AGENTS.md"], "create-claude-md"), ("codex", "AGENTS.md", ["AGENTS.md"], "create-agents-md"), ("gemini", "GEMINI.md", ["GEMINI.md"], "create-gemini-md")]
    private static let secretPatterns = [".env", ".env.*", "!.env.example", "*.pem", "*.p12", "*.pfx", "id_rsa", "id_ed25519", ".netrc"]
    private static let lockfiles = ["package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock"]
    private static let ignoreTemplate = "# Dependencies\nnode_modules/\n\n# Build output\ndist/\nbuild/\ncoverage/\n\n# Environment and keys\n.env\n.env.*\n!.env.example\n*.pem\n*.p12\n*.pfx\nid_rsa\nid_ed25519\n.netrc\n\n# OS\n.DS_Store\nThumbs.db\n"
    private func text(root: String, relative: String, context: NativeRPCContext, maximum: Int = 1_048_576) async throws -> String? {
        let base = try await projects.files.authority.authorize(root, context: context, intent: .read)
        let lexical = base.appendingPathComponent(relative).standardizedFileURL
        guard BackendFilesystemAuthority.within(lexical, base), !relative.hasPrefix("/"), !relative.contains("\0") else { throw NativeRPCError.invalidArguments("Readiness only reads project-relative files.") }
        if !FileManager.default.fileExists(atPath: lexical.path) { return nil }
        let url = try await projects.files.authority.resolve(root: root, relative: relative, context: context, intent: .read, mustExist: false).path
        guard let data = try BackendAccountFiles.boundedRead(url, maximum: maximum) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { throw NativeRPCError.malformed("\(relative) is not readable UTF8 text.") }; return text
    }
    private func exists(root: String, relative: String, context: NativeRPCContext) async throws -> Bool {
        let base = try await projects.files.authority.authorize(root, context: context, intent: .read)
        let lexical = base.appendingPathComponent(relative).standardizedFileURL
        guard BackendFilesystemAuthority.within(lexical, base), !relative.hasPrefix("/"), !relative.contains("\0") else { throw NativeRPCError.invalidArguments("Readiness only checks project-relative files.") }
        if !FileManager.default.fileExists(atPath: lexical.path) { return false }
        let url = try await projects.files.authority.resolve(root: root, relative: relative, context: context, intent: .read, mustExist: false).path
        return FileManager.default.fileExists(atPath: url.path)
    }
    private func rootNames(_ root: String, context: NativeRPCContext) async throws -> [String] {
        let actual = try await projects.files.authority.authorize(root, context: context, intent: .read)
        let values = try FileManager.default.contentsOfDirectory(at: actual, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [])
        guard values.count <= 10_000 else { throw NativeRPCError.malformed("The project root exceeds the readiness directory budget.") }
        return try values.filter { let info = try $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]); return info.isRegularFile == true && info.isSymbolicLink != true }.map(\.lastPathComponent).sorted()
    }
    private struct Package: Sendable { let raw: NativeRPCValue; var scripts: NativeRPCValue { raw["scripts"] }; var dependencies: NativeRPCValue { raw["dependencies"].merging(raw["devDependencies"]) }; var npm: Bool { raw["packageManager"].string.map { $0.hasPrefix("npm@") } ?? true } }
    private func package(_ root: String, context: NativeRPCContext) async throws -> Package? {
        guard let contents = try await text(root: root, relative: "package.json", context: context, maximum: 2 * 1_048_576) else { return nil }
        let raw = try NativeRPCValue.parseJSON(Data(contents.utf8)); guard raw.fields != nil else { throw NativeRPCError.malformed("package.json is not an object.") }; return Package(raw: raw)
    }
    private static func check(_ id: String, _ title: String, _ status: ReadinessStatus, _ detail: String, fix: ReadinessFix? = nil, opens: String? = nil) -> ReadinessCheck {
        ReadinessCheck(id: id, title: title, status: status, weight: weights[id] ?? 0, detail: detail, fix: fix, gate: id == "secrets", opens: opens)
    }
    private static func fix(_ id: String, _ label: String, _ description: String, _ paths: [String], destructive: Bool = false) -> ReadinessFix { ReadinessFix(id: id, label: label, description: description, touches: paths, destructive: destructive) }
    public static func score(_ checks: [ReadinessCheck]) -> (score: Int, band: ReadinessBand, cappedBy: String?) {
        let applicable = checks.filter { $0.status != .skip }, possible = applicable.reduce(0) { $0 + $1.weight }
        let earned = applicable.reduce(0) { $0 + $1.weight * ($1.status == .pass ? 1 : $1.status == .warn ? 0.5 : 0) }
        var result = possible > 0 ? Int((earned / possible * 100).rounded()) : 0, cap: String?
        if let secrets = checks.first(where: { $0.id == "secrets" }), secrets.status == .fail || secrets.status == .warn {
            let maximum = secrets.status == .fail ? 39 : 79; if result > maximum { result = maximum; cap = secrets.title }
        }
        let band: ReadinessBand = result >= 85 ? .strong : result >= 65 ? .fair : result >= 40 ? .weak : .atRisk
        return (result, band, cap)
    }
    private static func meaningful(_ text: String) -> Int { text.components(separatedBy: .newlines).filter { line in let t = line.trimmingCharacters(in: .whitespaces); return !t.isEmpty && !t.hasPrefix("<!--") && BackendUsageIO.matches("^(-{3,}|={3,}|\\*{3,})$", t).isEmpty }.count }
    private static func skeleton(_ text: String, template: String) -> Bool {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, original = Set(template.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) })
        return !lines.isEmpty && lines.allSatisfy(original.contains)
    }
    private static func instructionsTemplate(_ file: String) -> String { "# \(file)\n\nInstructions for an AI agent working in this repository.\n\n## What this is\n\n<!-- One paragraph: what the project does and who it is for. -->\n\n## Run it\n\n```sh\n# install\n# start\n```\n\n## Test it\n\n```sh\n# the exact command that proves a change is sound\n```\n\n## Layout\n\n<!-- The three or four directories that matter, and what lives in each. -->\n\n## Conventions\n\n<!-- Style, naming and patterns you actually enforce in review. -->\n\n## Do not\n\n<!-- Files, directories or commands an agent must leave alone. -->\n" }
    private static func readmeTemplate(_ name: String) -> String { "# \(name)\n\n<!-- One line: what this is. -->\n\n## Install\n\n```sh\n# install command\n```\n\n## Run\n\n```sh\n# run command\n```\n\n## Test\n\n```sh\n# test command\n```\n" }
    private func instructions(_ root: String, agent: String?, context: NativeRPCContext) async throws -> ReadinessCheck {
        let entry = Self.agents.first { $0.id == agent }, candidates = entry?.candidates ?? ["CLAUDE.md", ".claude/CLAUDE.md", "AGENTS.md", "GEMINI.md"]
        let title = "Agent instructions present and useful"
        for file in candidates {
            guard let contents = try await text(root: root, relative: file, context: context) else { continue }
            let count = Self.meaningful(contents)
            if Self.skeleton(contents, template: Self.instructionsTemplate(URL(fileURLWithPath: file).lastPathComponent)) { return Self.check("claude-md", title, .warn, "\(file) is still the unfilled skeleton. Add the actual project, run, test and convention details.", opens: file) }
            if count < 12 { return Self.check("claude-md", title, .warn, "\(file) contains only \(count) meaningful lines.", opens: file) }
            if count > 400 { return Self.check("claude-md", title, .warn, "\(file) contains \(count) meaningful lines; move depth into linked files to reduce repeated context.", opens: file) }
            let command = "```|(^|[\\s`(\"'])(npm|pnpm|yarn|bun|npx|make|cargo|pytest|uv|dotnet|gradle|mvn|docker|deno|rake|tox|go (run|test|build)|python3? -m|\\./[\\w.-]+\\.sh)\\b"
            return Self.check("claude-md", title, BackendUsageIO.matches(command, contents, insensitive: true).isEmpty ? .warn : .pass, "\(file) contains \(count) meaningful lines" + (BackendUsageIO.matches(command, contents, insensitive: true).isEmpty ? " but no runnable command." : " and documents runnable commands."), opens: file)
        }
        let offered = entry ?? Self.agents[0]
        return Self.check("claude-md", title, .fail, agent == nil ? "No instructions file read by a known agent was found." : "\(BackendAccountProfile.providerLabel(agent!)) has no instructions file here.", fix: Self.fix(offered.fix, "Create \(offered.file)", "Writes an instructions skeleton for this agent. Refuses to overwrite an existing file.", [offered.file]))
    }
    private static func secretFile(_ path: String) -> Bool {
        if !BackendUsageIO.matches("\\.(example|sample|template|dist|defaults?)$", path, insensitive: true).isEmpty { return false }
        return !BackendUsageIO.matches("(^|/)(\\.env(\\.[^/]+)?|[^/]+\\.(pem|p12|pfx|jks|keystore)|id_(rsa|dsa|ecdsa|ed25519)|\\.netrc|\\.pgpass|secrets?\\.(json|ya?ml)|credentials\\.json|serviceaccount[^/]*\\.json)$", path, insensitive: true).isEmpty
    }
    private func secretsAmong(_ paths: [String], root: String, context: NativeRPCContext) async throws -> [String] {
        guard paths.count <= 100_000 else { throw NativeRPCError.malformed("The tracked-file list exceeds the readiness scan budget.") }
        var found: [String] = []
        for path in paths {
            try Task.checkCancellation()
            if Self.secretFile(path) { found.append(path) }
            else if URL(fileURLWithPath: path).lastPathComponent == ".npmrc", let contents = try await text(root: root, relative: path, context: context), !BackendUsageIO.matches("(?m)^\\s*(//.*:)?_auth(Token)?\\s*=", contents, insensitive: true).isEmpty { found.append(path) }
        }
        return found
    }
    private static func ignoreCovers(_ ignore: BackendFilesystemIgnore, _ path: String, directory: Bool) -> Bool {
        // Readiness uses the raw rules, never the file tree's unconditional
        // node_modules/.git exclusions; those would falsely pass a missing rule.
        let segments = path.split(separator: "/").map(String.init)
        for index in segments.indices {
            let final = index == segments.count - 1, partial = segments[...index].joined(separator: "/")
            var covered = false
            for rule in ignore.rules where !rule.directoryOnly || !final || directory { if rule.matches(partial, directory: !final || directory) { covered = !rule.negated } }
            if covered { return true }
        }
        return false
    }
    private static func testRunner(_ deps: NativeRPCValue) -> (String, String)? {
        for (key, body) in [("vitest", "vitest run"), ("jest", "jest"), ("mocha", "mocha"), ("ava", "ava"), ("playwright", "playwright test"), ("@playwright/test", "playwright test")] where deps.has(key) { return ("test", body) }; return nil
    }
    private static func linter(_ deps: NativeRPCValue) -> (String, String)? {
        for (key, body) in [("eslint", "eslint ."), ("@biomejs/biome", "biome check ."), ("oxlint", "oxlint"), ("prettier", "prettier --check .")] where deps.has(key) { return ("lint", body) }; return nil
    }
    private static func scriptFix(_ id: String, _ script: String, _ body: String, replace: Bool = false) -> ReadinessFix { fix(id, replace ? "Replace the placeholder" : "Add \(script) script", "\(replace ? "Replaces npm's placeholder with" : "Adds") \"\(script)\": \"\(body)\" in package.json, using an installed dependency.", ["package.json"], destructive: replace) }
    private func tracked(_ root: String, context: NativeRPCContext) async throws -> [String] {
        let result = try await git.runner.run(cwd: root, arguments: ["ls-files", "-z"], context: context, writing: false, timeoutMilliseconds: 8000, maximumBytes: 16 * 1024 * 1024)
        guard result.ok else { throw NativeRPCError(code: "filesystem", message: "Git could not list tracked files: " + String(result.stderr.prefix(200))) }
        return result.stdout.split(separator: "\0").map(String.init)
    }
    public func scan(project: String, context: NativeRPCContext) async throws -> ReadinessReport {
        _ = try await projects.requireKnown(project); _ = try await projects.files.authority.authorize(project, context: context, intent: .read)
        let statusResult: Result<NativeRPCValue, any Error>
        do { statusResult = .success(try await git.status(cwd: project, context: context)) } catch { statusResult = .failure(error) }
        let packageResult: Result<Package?, any Error>
        do { packageResult = .success(try await package(project, context: context)) } catch { packageResult = .failure(error) }
        var checks: [ReadinessCheck] = []
        func guardCheck(_ id: String, _ title: String, _ run: () async throws -> ReadinessCheck) async throws -> ReadinessCheck {
            do { try Task.checkCancellation(); return try await run() } catch is CancellationError { throw CancellationError() } catch { return Self.check(id, title, id == "secrets" ? .warn : .skip, "This check could not run: " + error.localizedDescription) }
        }
        checks.append(try await guardCheck("secrets", "No secrets committed") {
            let status = try statusResult.get(), names = try await rootNames(project, context: context)
            if status["repo"].bool != true, status["reason"].string != "not-a-repo" { throw NativeRPCError.malformed("Git could not establish whether secrets are tracked.") }
            let trackedPaths = status["repo"].bool == true ? try await tracked(project, context: context) : []
            let committed = try await secretsAmong(trackedPaths, root: project, context: context)
            if !committed.isEmpty { return Self.check("secrets", "No secrets committed", .fail, "Git is tracking \(committed.count) credential files: \(committed.prefix(4).joined(separator: ", ")). Untracking does not erase past commits; rotate exposed credentials.", fix: Self.fix("untrack-secrets", "Untrack and ignore", "Adds ignore rules and removes tracked secrets from the Git index. Files remain on disk and in past commits.", [".gitignore", "git index"], destructive: true)) }
            let ignore = BackendFilesystemIgnore(texts: [try await text(root: project, relative: ".gitignore", context: context) ?? ""])
            let exposed = names.filter { Self.secretFile($0) && !Self.ignoreCovers(ignore, $0, directory: false) }
            return Self.check("secrets", "No secrets committed", exposed.isEmpty ? .pass : .warn, exposed.isEmpty ? "No credential files are tracked or sitting unignored in the project root." : "\(exposed.prefix(4).joined(separator: ", ")) is present without ignore coverage.", fix: exposed.isEmpty ? nil : Self.fix("ignore-secrets", "Ignore secret files", "Appends standard secret patterns, leaving examples allowed.", [".gitignore"]))
        })
        checks.append(try await guardCheck("claude-md", "Agent instructions present and useful") { try await instructions(project, agent: nil, context: context) })
        checks.append(try await guardCheck("test-script", "Tests can be run with one command") {
            guard let pkg = try packageResult.get() else {
                for (file, pattern, label) in [("pyproject.toml", "\\bpytest\\b", "pytest"), ("Cargo.toml", ".", "cargo test"), ("go.mod", ".", "go test"), ("Makefile", "(?m)^test\\s*:", "make test")] {
                    if let content = try await text(root: project, relative: file, context: context), !BackendUsageIO.matches(pattern, content).isEmpty { return Self.check("test-script", "Tests can be run with one command", .pass, "\(file) provides \(label).") }
                }
                return Self.check("test-script", "Tests can be run with one command", .skip, "No recognised test manifest or entry point.")
            }
            let script = pkg.scripts["test"].string, placeholder = script?.localizedCaseInsensitiveContains("no test specified") == true
            if let script, !script.trimmingCharacters(in: .whitespaces).isEmpty, !placeholder { return Self.check("test-script", "Tests can be run with one command", .pass, "The test script runs \(script).", opens: "package.json") }
            let runner = Self.testRunner(pkg.dependencies)
            return Self.check("test-script", "Tests can be run with one command", .fail, placeholder ? "The test script is still npm's placeholder." : "No test script was found.", fix: runner.map { Self.scriptFix(placeholder ? "replace-test-script" : "add-test-script", $0.0, $0.1, replace: placeholder) }, opens: "package.json")
        })
        checks.append(try await guardCheck("git-repo", "Git repository initialised") {
            let status = try statusResult.get()
            if status["repo"].bool == true { return Self.check("git-repo", "Git repository initialised", .pass, "Git recognises this project as a repository.") }
            guard status["reason"].string == "not-a-repo" else { throw NativeRPCError.malformed(status["message"].string ?? "Git was unavailable.") }
            return Self.check("git-repo", "Git repository initialised", .fail, "This folder is not a Git repository.", fix: Self.fix("git-init", "Initialise Git", "Runs git init without staging or committing files.", [".git"]))
        })
        checks.append(try await guardCheck("gitignore", ".gitignore covers the basics") {
            guard let contents = try await text(root: project, relative: ".gitignore", context: context) else { return Self.check("gitignore", ".gitignore covers the basics", .fail, "No .gitignore was found.", fix: Self.fix("create-gitignore", "Create .gitignore", "Creates basic dependency, build and secret ignore rules, leaving examples allowed.", [".gitignore"])) }
            let pkg = try packageResult.get(), rules = BackendFilesystemIgnore(texts: [contents]); var wanted = [".env"]
            if pkg != nil { wanted.append("node_modules") }; for path in ["dist", "build"] { if try await exists(root: project, relative: path, context: context) { wanted.append(path) } }
            let missing = wanted.filter { !Self.ignoreCovers(rules, $0, directory: $0 != ".env") }
            return Self.check("gitignore", ".gitignore covers the basics", missing.isEmpty ? .pass : .warn, missing.isEmpty ? ".gitignore covers \(wanted.joined(separator: ", "))." : ".gitignore does not cover \(missing.joined(separator: ", ")).", fix: missing.isEmpty ? nil : Self.fix("patch-gitignore", "Add missing patterns", "Appends essential missing patterns without editing existing rules.", [".gitignore"]), opens: ".gitignore")
        })
        checks.append(try await guardCheck("readme", "README for humans") {
            guard let name = try await rootNames(project, context: context).first(where: { !BackendUsageIO.matches("^readme(\\.|$)", $0, insensitive: true).isEmpty }) else { return Self.check("readme", "README for humans", .fail, "No README was found.", fix: Self.fix("create-readme", "Create README.md", "Writes a short README skeleton and refuses to overwrite an existing README.", ["README.md"])) }
            let contents = try await text(root: project, relative: name, context: context) ?? "", count = Self.meaningful(contents)
            return Self.check("readme", "README for humans", count < 5 || Self.skeleton(contents, template: Self.readmeTemplate(URL(fileURLWithPath: project).lastPathComponent)) ? .warn : .pass, "\(name) contains \(count) meaningful lines.", opens: name)
        })
        checks.append(try await guardCheck("typecheck-script", "Types can be checked without building") {
            let pkg = try packageResult.get(), hasConfig = try await exists(root: project, relative: "tsconfig.json", context: context), hasTS = pkg?.dependencies.has("typescript") == true
            guard hasConfig || hasTS else { return Self.check("typecheck-script", "Types can be checked without building", .skip, "Not a TypeScript project.") }
            guard let pkg else { return Self.check("typecheck-script", "Types can be checked without building", .warn, "tsconfig.json exists without a package script manifest.", opens: "tsconfig.json") }
            let found = pkg.scripts.fields?.first { !BackendUsageIO.matches("^(typecheck|type-check|check-types|tsc)$", $0.key, insensitive: true).isEmpty || !BackendUsageIO.matches("tsc\\b[^&|]*--noEmit", $0.value.string ?? "").isEmpty }
            return Self.check("typecheck-script", "Types can be checked without building", found == nil ? .fail : .pass, found.map { "The \($0.key) script checks types." } ?? "No typecheck script was found.", fix: found == nil && hasTS ? Self.scriptFix("add-typecheck-script", "typecheck", "tsc --noEmit") : nil, opens: "package.json")
        })
        checks.append(try await guardCheck("git-clean", "Working tree is reviewable") {
            let status = try statusResult.get(); guard status["repo"].bool == true else { return Self.check("git-clean", "Working tree is reviewable", .skip, "No repository status is available.") }
            let count = Set(["staged", "unstaged", "untracked", "conflicted"].flatMap { status[$0].elements ?? [] }.compactMap { $0["path"].string }).count
            return Self.check("git-clean", "Working tree is reviewable", count == 0 ? .pass : count >= 20 ? .fail : .warn, count == 0 ? "The working tree is clean." : "\(count) files have uncommitted changes.")
        })
        checks.append(try await guardCheck("lint-script", "Lint or format check") {
            guard let pkg = try packageResult.get() else { return Self.check("lint-script", "Lint or format check", .skip, "No package.json to inspect.") }
            let found = pkg.scripts.fields?.first { !BackendUsageIO.matches("^(lint|format|fmt|check)$", $0.key, insensitive: true).isEmpty || !BackendUsageIO.matches("\\b(eslint|biome|oxlint|prettier|standard)\\b", $0.value.string ?? "").isEmpty }, runner = Self.linter(pkg.dependencies)
            return Self.check("lint-script", "Lint or format check", found == nil ? .warn : .pass, found.map { "The \($0.key) script checks style." } ?? "No lint or format-check script was found.", fix: found == nil ? runner.map { Self.scriptFix("add-lint-script", $0.0, $0.1) } : nil, opens: "package.json")
        })
        checks.append(try await guardCheck("lockfile", "Dependencies are pinned") {
            guard let pkg = try packageResult.get() else { if try await exists(root: project, relative: "Cargo.toml", context: context) { let locked = try await exists(root: project, relative: "Cargo.lock", context: context); return Self.check("lockfile", "Dependencies are pinned", locked ? .pass : .warn, locked ? "Cargo.lock pins dependencies." : "Cargo.toml exists without Cargo.lock.") }; return Self.check("lockfile", "Dependencies are pinned", .skip, "No recognised dependency manifest.") }
            for path in Self.lockfiles { if try await exists(root: project, relative: path, context: context) { return Self.check("lockfile", "Dependencies are pinned", .pass, "\(path) pins the dependency graph.", opens: path) } }
            return Self.check("lockfile", "Dependencies are pinned", .warn, pkg.npm ? "No lockfile was found." : "The declared package manager must create its own lockfile.", fix: pkg.npm ? Self.fix("create-lockfile", "Create lockfile", "Runs npm install --package-lock-only --ignore-scripts. May contact the registry; does not run project scripts.", ["package-lock.json"]) : nil)
        })
        var agents: [ReadinessForAgent] = []
        for entry in Self.agents { let instruction = try await guardCheck("claude-md", "Agent instructions present and useful") { try await instructions(project, agent: entry.id, context: context) }; let scored = Self.score(checks.map { $0.id == "claude-md" ? instruction : $0 }); agents.append(ReadinessForAgent(agent: entry.id, label: BackendAccountProfile.providerLabel(entry.id), file: entry.file, check: instruction, score: scored.score, band: scored.band, cappedBy: scored.cappedBy)) }
        let scored = Self.score(checks)
        return ReadinessReport(projectPath: project, score: scored.score, band: scored.band, checks: checks, cappedBy: scored.cappedBy, agents: agents, scannedAt: ISO8601DateFormatter().string(from: Date()))
    }
    private func write(_ contents: String, root: String, relative: String, context: NativeRPCContext, createOnly: Bool = false) async throws {
        let url = try await projects.files.authority.resolve(root: root, relative: relative, context: context, intent: .write, mustExist: false).path
        if createOnly {
            let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw NativeRPCError(code: "filesystem", message: "\(relative) already exists or could not be created.") }; defer { Darwin.close(fd) }
            let bytes = Array(contents.utf8); var written = 0
            try bytes.withUnsafeBytes { data in while written < bytes.count { let amount = Darwin.write(fd, data.baseAddress!.advanced(by: written), bytes.count - written); if amount < 0 { if errno == EINTR { continue }; throw POSIXError(.EIO) }; guard amount > 0 else { throw POSIXError(.EIO) }; written += amount } }
            guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
        } else {
            let mode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".readiness-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try BackendAccountFiles.writeAtomic(Data(contents.utf8), to: temporary)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary.path)
            guard Darwin.rename(temporary.path, url.path) == 0 else { throw POSIXError(.EIO) }
        }
    }
    private func appendIgnore(_ patterns: [String], root: String, context: NativeRPCContext) async throws -> ReadinessFixResult {
        let current = try await text(root: root, relative: ".gitignore", context: context) ?? "", ignore = BackendFilesystemIgnore(texts: [current]); var add: [String] = []
        for pattern in patterns {
            if current.components(separatedBy: .newlines).contains(pattern) { continue }
            if pattern.hasPrefix("!") { add.append(pattern); continue }
            let sample = pattern.replacingOccurrences(of: "*", with: "sample").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !Self.ignoreCovers(ignore, sample, directory: pattern.hasSuffix("/")) { add.append(pattern) }
        }
        if add.isEmpty { return ReadinessFixResult(ok: true, message: "The requested patterns are already covered.") }
        let block = (current.isEmpty || current.hasSuffix("\n") ? current : current + "\n") + "\n# added by \(appName) — AI readiness\n" + add.joined(separator: "\n") + "\n"
        try await write(block, root: root, relative: ".gitignore", context: context)
        return ReadinessFixResult(ok: true, message: "Added missing ignore patterns.", changed: [".gitignore"])
    }
    private func addScript(_ script: String, body: String, root: String, context: NativeRPCContext, placeholderOnly: Bool = false) async throws -> ReadinessFixResult {
        guard let pkg = try await package(root, context: context) else { return .init(ok: false, message: "package.json is missing.") }
        let existing = pkg.scripts[script]
        if placeholderOnly { guard existing.string?.localizedCaseInsensitiveContains("no test specified") == true else { return .init(ok: false, message: "The current test script is not npm's placeholder; it was left alone.") } }
        else if existing != .missing { return .init(ok: false, message: "The \(script) script already exists; it was left alone.") }
        let patched = pkg.raw.setting("scripts", pkg.scripts.setting(script, .string(body)))
        guard let json = patched.foundation else { throw NativeRPCError.malformed("The package script update could not be encoded.") }
        let source = try await text(root: root, relative: "package.json", context: context) ?? ""
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .withoutEscapingSlashes])
        // Preserve ordinary spaces/tabs rather than serialising a new package
        // format. Unknown fields survive the native object update.
        var result = String(decoding: data, as: UTF8.self)
        let indent = BackendUsageIO.matches("(?m)^([ \\t]+)\\\"", source).first.flatMap { BackendUsageIO.group($0, 1, source) } ?? "  "
        result = result.components(separatedBy: "\n").map { line in
            let spaces = line.prefix { $0 == " " }.count
            return String(repeating: indent, count: spaces / 2) + String(line.dropFirst(spaces))
        }.joined(separator: "\n")
        try await write(result + "\n", root: root, relative: "package.json", context: context)
        return .init(ok: true, message: "Updated the \(script) script.", changed: ["package.json"])
    }
    public func fix(project: String, id: String, context: NativeRPCContext, requireOffered: Bool = false) async throws -> ReadinessFixResult {
        try authorizeMutation(context); guard Self.fixIDs.contains(id) else { return .init(ok: false, message: "Unknown readiness fix.") }
        if id == "upgrade-agent-cli" { return try await tools.upgradeGemini(context: context) }
        _ = try await projects.requireKnown(project); _ = try await projects.files.authority.authorize(project, context: context, intent: .write)
        if requireOffered {
            let report = try await scan(project: project, context: context), offered = report.checks.compactMap(\.fix) + report.agents.compactMap { $0.check.fix }
            guard offered.contains(where: { $0.id == id }) else { return .init(ok: false, message: "This project's current scan is not offering that fix.") }
        }
        if let entry = Self.agents.first(where: { $0.fix == id }) {
            try await write(Self.instructionsTemplate(entry.file), root: project, relative: entry.file, context: context, createOnly: true)
            return .init(ok: true, message: "Created \(entry.file). Fill in its project details and commands.", changed: [entry.file])
        }
        switch id {
        case "create-readme":
            guard try await rootNames(project, context: context).allSatisfy({ BackendUsageIO.matches("^readme(\\.|$)", $0, insensitive: true).isEmpty }) else { return .init(ok: false, message: "A README already exists.") }
            try await write(Self.readmeTemplate(URL(fileURLWithPath: project).lastPathComponent), root: project, relative: "README.md", context: context, createOnly: true); return .init(ok: true, message: "Created README.md. Fill in the placeholders.", changed: ["README.md"])
        case "create-gitignore": try await write(Self.ignoreTemplate, root: project, relative: ".gitignore", context: context, createOnly: true); return .init(ok: true, message: "Created .gitignore.", changed: [".gitignore"])
        case "ignore-secrets": return try await appendIgnore(Self.secretPatterns, root: project, context: context)
        case "patch-gitignore":
            var wanted = Self.secretPatterns; if try await package(project, context: context) != nil { wanted.append("node_modules/") }; for path in ["dist", "build"] { if try await exists(root: project, relative: path, context: context) { wanted.append(path + "/") } }; return try await appendIgnore(wanted, root: project, context: context)
        case "git-init":
            let result = try await git.initialize(cwd: project, context: context); return .init(ok: result["repo"].bool == true, message: result["repo"].bool == true ? "Git is initialised. Nothing was staged or committed." : result["message"].string ?? "Git could not be initialised.", changed: result["repo"].bool == true ? [".git"] : [])
        case "untrack-secrets":
            let trackedPaths = try await tracked(project, context: context)
            let secrets = try await secretsAmong(trackedPaths, root: project, context: context)
            guard !secrets.isEmpty else { return .init(ok: false, message: "Git is no longer tracking any secret files.") }
            func anchored(_ path: String) -> String { "/" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "?", with: "\\?").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: " ", with: "\\ ") }
            let ignored = try await appendIgnore(Self.secretPatterns + secrets.map(anchored), root: project, context: context)
            var changed = ignored.changed
            for offset in stride(from: 0, to: secrets.count, by: 100) {
                let batch = Array(secrets[offset..<min(secrets.count, offset + 100)])
                let result = try await git.runner.run(cwd: project, arguments: ["rm", "--cached", "--quiet", "--"] + batch, context: context, writing: true, timeoutMilliseconds: 8000, maximumBytes: 1_048_576)
                guard result.ok else { return .init(ok: false, message: "Ignore rules were written, but Git could not untrack all secret files: " + String(result.stderr.prefix(300)), changed: changed) }; changed += batch
            }
            return .init(ok: true, message: "Untracked and ignored \(secrets.count) secret files. Files remain on disk and in past commits; rotate exposed credentials.", changed: changed)
        case "add-test-script", "replace-test-script", "add-lint-script", "add-typecheck-script":
            guard let pkg = try await package(project, context: context) else { return .init(ok: false, message: "package.json is missing.") }
            let runner: (String, String)? = id == "add-lint-script" ? Self.linter(pkg.dependencies) : id == "add-typecheck-script" ? (pkg.dependencies.has("typescript") ? ("typecheck", "tsc --noEmit") : nil) : Self.testRunner(pkg.dependencies)
            guard let runner else { return .init(ok: false, message: "No installed dependency supplies this check.") }
            return try await addScript(runner.0, body: runner.1, root: project, context: context, placeholderOnly: id == "replace-test-script")
        case "create-lockfile":
            guard let pkg = try await package(project, context: context), pkg.npm else { return .init(ok: false, message: "This project is missing package.json or declares a different package manager.") }
            for file in Self.lockfiles { if try await exists(root: project, relative: file, context: context) { return .init(ok: false, message: "\(file) already exists.") } }
            let outcome = try await tools.run("npm", arguments: ["install", "--package-lock-only", "--ignore-scripts"], cwd: project, timeout: 300_000, context: context)
            if try await exists(root: project, relative: "package-lock.json", context: context) { return .init(ok: true, message: "Wrote package-lock.json. Commit it to pin dependencies.", changed: ["package-lock.json"]) }
            return .init(ok: false, message: "No lockfile was written. " + String(outcome.output.suffix(400)))
        default: return .init(ok: false, message: "This readiness fix is unsupported.")
        }
    }
    public func invoke(_ channel: String, args: [NativeRPCValue], context: NativeRPCContext) async throws -> NativeRPCValue {
        switch channel {
        case "readiness:scan": return Self.wire(try await scan(project: (args.first ?? .missing).requireString("project path", nonempty: true), context: context))
        case "readiness:fix": return Self.wire(try await fix(project: args.first?.string ?? "", id: try (args.count > 1 ? args[1] : .missing).requireString("fix id", nonempty: true), context: context))
        default: throw BackendSessionFailure.unsupported("The native readiness channel is not registered.")
        }
    }
    public static func wire(_ fix: ReadinessFix) -> NativeRPCValue { BackendUsageIO.object([("id", .string(fix.id)), ("label", .string(fix.label)), ("description", .string(fix.description)), ("touches", .array(fix.touches.map(NativeRPCValue.string))), ("destructive", .bool(fix.destructive))]) }
    public static func wire(_ check: ReadinessCheck) -> NativeRPCValue { BackendUsageIO.object([("id", .string(check.id)), ("title", .string(check.title)), ("status", .string(check.status.rawValue)), ("weight", .number(check.weight)), ("detail", .string(check.detail)), ("fix", check.fix.map(wire) ?? .null), ("gate", .bool(check.gate)), ("opens", BackendUsageIO.string(check.opens))]) }
    public static func wire(_ report: ReadinessReport) -> NativeRPCValue {
        let agents = report.agents.map { BackendUsageIO.object([("agent", .string($0.agent)), ("label", .string($0.label)), ("file", .string($0.file)), ("check", wire($0.check)), ("score", .number(Double($0.score))), ("band", .string($0.band.rawValue)), ("cappedBy", BackendUsageIO.string($0.cappedBy))]) }
        return BackendUsageIO.object([("projectPath", .string(report.projectPath)), ("score", .number(Double(report.score))), ("band", .string(report.band.rawValue)), ("checks", .array(report.checks.map(wire))), ("cappedBy", BackendUsageIO.string(report.cappedBy)), ("agents", .array(agents)), ("scannedAt", .string(report.scannedAt))])
    }
    public static func wire(_ result: ReadinessFixResult) -> NativeRPCValue { BackendUsageIO.object([("ok", .bool(result.ok)), ("message", .string(result.message)), ("changed", .array(result.changed.map(NativeRPCValue.string)))]) }
}
