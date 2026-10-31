import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// Actionable readiness uses the existing scan owner. Preview ids grant no
/// permission: every application calls the supplied real consent/effect gate.
public actor BackendAIRReadinessService {
    public typealias Scan = @Sendable (String, NativeRPCContext) async throws -> ReadinessReport
    public typealias CallerIdentity = @Sendable (NativeRPCContext) async throws -> String
    public typealias Approval = @Sendable (NativeRPCContext, AIRReadinessFixPreview) async throws -> Void
    public static let channels: Set<String> = ["readiness:listChecks", "readiness:explain", "readiness:previewFix", "readiness:fixApproved", "readiness:recheck"]
    private struct Ticket: Sendable {
        let preview: AIRReadinessFixPreview
        let identity: String
        let issued: Date
        let plan: BackendAIRFilePlan
    }
    private let projects: BackendProjectService
    private let scan: Scan
    private let callerIdentity: CallerIdentity
    private let approve: Approval
    private let authorizeMutation: @Sendable (NativeRPCContext) throws -> Void
    private let now: @Sendable () -> Date
    private var previews: [String: Ticket] = [:]
    private let lifetime: TimeInterval = 300

    public init(readiness: BackendReadinessService, projects: BackendProjectService,
                callerIdentity: @escaping CallerIdentity, approve: @escaping Approval,
                authorizeMutation: @escaping @Sendable (NativeRPCContext) throws -> Void,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.projects = projects; scan = { try await readiness.scan(project: $0, context: $1) }
        self.callerIdentity = callerIdentity; self.approve = approve
        self.authorizeMutation = authorizeMutation; self.now = now
    }
    /// Test seam: scratch-project tests supply their scan, not a second scan in
    /// production. Both initialisers require the actual approval suppliers.
    public init(projects: BackendProjectService, scan: @escaping Scan,
                callerIdentity: @escaping CallerIdentity, approve: @escaping Approval,
                authorizeMutation: @escaping @Sendable (NativeRPCContext) throws -> Void,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.projects = projects; self.scan = scan; self.callerIdentity = callerIdentity
        self.approve = approve; self.authorizeMutation = authorizeMutation; self.now = now
    }
    private func failure(_ code: String, _ message: String) -> NativeRPCError { .init(code: code, message: message) }
    private func checkedDate() throws -> Date {
        let date = now()
        guard date.timeIntervalSince1970.isFinite else { throw failure("unavailable", "The approval clock is unavailable. Re-check before trying again.") }
        return date
    }
    private func prune(_ date: Date) {
        previews = previews.filter { date >= $0.value.issued && date.timeIntervalSince($0.value.issued) < lifetime }
    }
    public func listChecks(project: String, context: NativeRPCContext) async throws -> ReadinessReport {
        _ = try await projects.requireKnown(project)
        _ = try await projects.files.authority.authorize(project, context: context, intent: .read)
        try Task.checkCancellation()
        return try await scan(project, context)
    }
    public func recheck(project: String, context: NativeRPCContext) async throws -> ReadinessReport {
        try await listChecks(project: project, context: context)
    }
    private func selected(_ report: ReadinessReport, checkID: String, agent: String?) throws -> ReadinessCheck {
        if let agent {
            guard let match = report.agents.first(where: { $0.agent == agent }) else {
                throw failure("invalid-check", "That agent-specific check was not found. List the project's checks again.")
            }
            if checkID == "claude-md" { return match.check }
        }
        guard let check = report.checks.first(where: { $0.id == checkID }) else {
            throw failure("invalid-check", "That readiness check was not found. List the project's checks again.")
        }
        return check
    }
    public func explain(project: String, checkID: String, agent: String? = nil,
                        context: NativeRPCContext) async throws -> AIRReadinessActionPlan {
        let report = try await listChecks(project: project, context: context)
        return AIRReadinessActions.plan(for: try selected(report, checkID: checkID, agent: agent), projectPath: project, agent: agent)
    }
    private func fingerprint(_ check: ReadinessCheck, agent: String?) -> String {
        let value = BackendReadinessService.wire(check).setting("agent", agent.map(NativeRPCValue.string) ?? .null)
        return SHA256.hash(data: Data(value.compact.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func plan(project: String, check: ReadinessCheck, agent: String?, context: NativeRPCContext) async throws -> BackendAIRFilePlan {
        guard AIRReadinessActions.canAutomaticallyFix(check, agent: agent), let fix = check.fix else {
            let guidance = AIRReadinessActions.plan(for: check, projectPath: project, agent: agent)
            throw failure("fix-unavailable", guidance.manualReason ?? "This check needs the listed steps or an AI session. AIR cannot make a safe exact preview for it.")
        }
        let root = try await projects.files.authority.authorize(project, context: context, intent: .read)
        let relative: String
        let createContents: String?
        switch fix.id {
        case "create-claude-md": relative = "CLAUDE.md"; createContents = Self.instructions(relative)
        case "create-agents-md": relative = "AGENTS.md"; createContents = Self.instructions(relative)
        case "create-gemini-md": relative = "GEMINI.md"; createContents = Self.instructions(relative)
        case "create-readme":
            relative = "README.md"
            let name = root.lastPathComponent.components(separatedBy: .newlines).joined(separator: " ")
            createContents = "# \(name)\n\n<!-- One line: what this is. -->\n\n## Install\n\n```sh\n# install command\n```\n\n## Run\n\n```sh\n# run command\n```\n\n## Test\n\n```sh\n# test command\n```\n"
        case "create-gitignore":
            relative = ".gitignore"
            let actualNames = try Self.exposedCredentialNames(root: root)
            createContents = Self.ignoreTemplate + (actualNames.isEmpty ? "" : "\n# Credential files already present (names only)\n" + actualNames.map(Self.anchored).joined(separator: "\n") + "\n!.env.example\n")
        case "ignore-secrets", "patch-gitignore": relative = ".gitignore"; createContents = nil
        default: throw failure("fix-unavailable", "This fix needs the listed steps or an AI session.")
        }
        _ = try await projects.files.authority.resolve(root: project, relative: relative, context: context, intent: .read, mustExist: false)
        let (rootIdentity, before) = try BackendAIRFilePlan.snapshot(root: root.path, relative: relative)
        let added: String
        if let createContents {
            guard before == nil else { throw failure("stale-preview", "The file now exists. Nothing will be overwritten; re-check the project.") }
            added = createContents
        } else {
            let current = before.map { String(decoding: $0.bytes, as: UTF8.self) } ?? ""
            var wanted = Self.secretPatterns.filter { !$0.hasPrefix("!") }
            wanted += try Self.exposedCredentialNames(root: root).map(Self.anchored)
            if fix.id == "patch-gitignore" {
                if try await exists(project, "package.json", context) { wanted.append("node_modules/") }
                for folder in ["dist", "build"] { if try await exists(project, folder, context) { wanted.append(folder + "/") } }
            }
            let rules = BackendFilesystemIgnore(texts: [current])
            let missing = Array(NSOrderedSet(array: wanted)).compactMap { $0 as? String }.filter { pattern in
                let sample = pattern.hasPrefix("/") ? Self.unescape(String(pattern.dropFirst())) : pattern.replacingOccurrences(of: "*", with: "sample").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return !Self.covers(rules, sample, directory: pattern.hasSuffix("/"))
            }
            guard !missing.isEmpty else { throw failure("stale-preview", "The requested ignore patterns are already covered. Re-check the project.") }
            // Keep the example exception last, even if an earlier identical
            // positive rule was undone by a later negation.
            added = (current.isEmpty || current.hasSuffix("\n") ? "" : "\n") + "\n# added by Terminal Deck — AI readiness\n" + (missing + ["!.env.example"]).joined(separator: "\n") + "\n"
        }
        let bytes = Data(added.utf8)
        guard bytes.count <= 64 * 1024 else { throw failure("fix-unavailable", "The exact added text is too large for a safe approval preview. Use the listed steps or ask an AI.") }
        return BackendAIRFilePlan(root: root.path, rootIdentity: rootIdentity, relative: relative, before: before, added: bytes)
    }
    private func exists(_ project: String, _ relative: String, _ context: NativeRPCContext) async throws -> Bool {
        let root = try await projects.files.authority.authorize(project, context: context, intent: .read)
        let path = root.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: path.path) else { return false }
        _ = try await projects.files.authority.resolve(root: project, relative: relative, context: context, intent: .read)
        return true
    }
    public func previewFix(project: String, checkID: String, agent: String? = nil,
                           context: NativeRPCContext) async throws -> AIRReadinessFixPreview {
        let identity = try await callerIdentity(context)
        guard !identity.isEmpty else { throw failure("access-denied", "A current authenticated caller is required for this preview.") }
        let report = try await listChecks(project: project, context: context)
        let check = try selected(report, checkID: checkID, agent: agent)
        let filePlan = try await plan(project: project, check: check, agent: agent, context: context)
        guard try await callerIdentity(context) == identity else { throw failure("access-denied", "The caller changed while making this preview. Re-check the project.") }
        try Task.checkCancellation()
        let date = try checkedDate(); prune(date)
        guard previews.count < 128 else { throw failure("too-many-previews", "Too many previews are waiting. Wait a few minutes and make a new preview.") }
        let id = UUID().uuidString
        let formatter = ISO8601DateFormatter()
        let scaffold = ["create-claude-md", "create-agents-md", "create-gemini-md", "create-readme"].contains(check.fix!.id)
        let summary = scaffold
            ? "Create \(filePlan.relative) with the exact draft shown below. Fill in its project details afterward; the draft alone will not make this check pass."
            : "\(filePlan.before == nil ? "Create" : "Append the shown ignore rules to") \(filePlan.relative). Existing file contents stay in place."
        let preview = AIRReadinessFixPreview(id: id, projectPath: project, checkID: checkID, agent: agent,
            fixID: check.fix!.id, title: check.fix!.label, summary: summary, changes: [filePlan.previewChange],
            checkFingerprint: fingerprint(check, agent: agent), createdAt: formatter.string(from: date),
            expiresAt: formatter.string(from: date.addingTimeInterval(lifetime)))
        previews[id] = Ticket(preview: preview, identity: identity, issued: date, plan: filePlan)
        return preview
    }
    /// Used by the core effect gate to obtain concrete consent text, never as
    /// consent itself. A different caller cannot inspect another preview.
    public func pendingPreview(previewID: String, context: NativeRPCContext) async throws -> AIRReadinessFixPreview {
        let date = try checkedDate(); prune(date)
        let identity = try await callerIdentity(context)
        guard let ticket = previews[previewID], ticket.identity == identity else {
            throw failure("stale-preview", "This preview expired, was used, or belongs to another caller. Make a new preview.")
        }
        _ = try await projects.requireKnown(ticket.preview.projectPath)
        _ = try await projects.files.authority.authorize(ticket.preview.projectPath, context: context, intent: .read)
        return ticket.preview
    }
    public func fixApproved(previewID: String, context: NativeRPCContext) async throws -> AIRReadinessFixOutcome {
        let date = try checkedDate(); prune(date)
        let identity = try await callerIdentity(context)
        guard let ticket = previews[previewID], ticket.identity == identity else {
            throw failure("stale-preview", "This preview expired, was used, or belongs to another caller. Make a new preview.")
        }
        // Reserve before awaiting consent. Replay, cancellation and denial all
        // consume it; a second request can never reuse the approval.
        previews[previewID] = nil
        let project = ticket.preview.projectPath
        let before = try await listChecks(project: project, context: context)
        let check = try selected(before, checkID: ticket.preview.checkID, agent: ticket.preview.agent)
        guard fingerprint(check, agent: ticket.preview.agent) == ticket.preview.checkFingerprint,
              try await plan(project: project, check: check, agent: ticket.preview.agent, context: context) == ticket.plan else {
            throw failure("stale-preview", "The check or file changed since this preview. Your changes were kept; make a new preview.")
        }
        try await approve(context, ticket.preview)
        try Task.checkCancellation()
        try authorizeMutation(context)
        let afterApproval = try checkedDate()
        guard try await callerIdentity(context) == ticket.identity,
              afterApproval >= ticket.issued, afterApproval.timeIntervalSince(ticket.issued) < lifetime else {
            throw failure("stale-preview", "The caller or preview changed while approval was open. Make a new preview.")
        }
        _ = try await projects.requireKnown(project)
        let root = try await projects.files.authority.authorize(project, context: context, intent: .write)
        guard root.path == ticket.plan.root else { throw failure("stale-preview", "The project folder changed. Make a new preview.") }
        _ = try await projects.files.authority.resolve(root: project, relative: ticket.plan.relative,
            context: context, intent: .write, mustExist: false)
        // Re-read the check and exact inputs after the person has answered.
        let fresh = try await listChecks(project: project, context: context)
        let current = try selected(fresh, checkID: ticket.preview.checkID, agent: ticket.preview.agent)
        guard fingerprint(current, agent: ticket.preview.agent) == ticket.preview.checkFingerprint,
              try await plan(project: project, check: current, agent: ticket.preview.agent, context: context) == ticket.plan else {
            throw failure("stale-preview", "The check or file changed while approval was open. Nothing was overwritten; make a new preview.")
        }
        try authorizeMutation(context)
        _ = try await projects.files.authority.authorize(project, context: context, intent: .write)
        guard try await callerIdentity(context) == ticket.identity else { throw failure("access-denied", "The caller changed while approval was open. Make a new preview.") }
        let finalDate = try checkedDate()
        guard finalDate >= ticket.issued, finalDate.timeIntervalSince(ticket.issued) < lifetime else { throw failure("stale-preview", "The preview expired while approval was open. Make a new preview.") }
        try authorizeMutation(context)
        try Task.checkCancellation()
        let result: ReadinessFixResult
        do {
            try ticket.plan.apply()
            await projects.files.invalidate(root: project)
            result = .init(ok: true, message: ticket.preview.summary + " Re-checked the project.", changed: [ticket.plan.relative])
        } catch {
            // A failed save may have written part of the appended/create-only
            // file. Never claim it was untouched or erase a concurrent edit.
            await projects.files.invalidate(root: project)
            result = .init(ok: false, message: (error as? NativeRPCError)?.message ?? "Saving could not be confirmed. Review the fresh check before retrying.", changed: [ticket.plan.relative])
        }
        let report = try await listChecks(project: project, context: context)
        return .init(result: result, report: report)
    }
    public func invoke(_ channel: String, args: [NativeRPCValue], context: NativeRPCContext) async throws -> NativeRPCValue {
        switch channel {
        case "readiness:listChecks", "readiness:recheck":
            try context.requireCount(args, 1...1)
            let project = try args[0].requireString("project path", nonempty: true)
            return AIRReadinessWire.wire(try await listChecks(project: project, context: context))
        case "readiness:explain", "readiness:previewFix":
            try context.requireCount(args, 2...3)
            let project = try args[0].requireString("project path", nonempty: true)
            let check = try args[1].requireString("check id", nonempty: true)
            let agent = args.count > 2 && !args[2].isNullish ? try args[2].requireString("agent", nonempty: true) : nil
            if channel == "readiness:explain" { return AIRReadinessWire.wire(try await explain(project: project, checkID: check, agent: agent, context: context)) }
            return AIRReadinessWire.wire(try await previewFix(project: project, checkID: check, agent: agent, context: context))
        case "readiness:fixApproved":
            try context.requireCount(args, 1...1)
            return AIRReadinessWire.wire(try await fixApproved(previewID: args[0].requireString("preview id", nonempty: true), context: context))
        case "readiness:fix":
            throw failure("approval-required", "Make an exact preview with readiness:previewFix, then approve it with readiness:fixApproved. A fix id or consent flag cannot authorize a change.")
        default: throw failure("missing-handler", "This AIR readiness action is unavailable.")
        }
    }
    private static let secretPatterns = [".env", ".env.*", "!.env.example", "*.pem", "*.p12", "*.pfx", "*.jks", "*.keystore", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", ".netrc", ".pgpass", "secret.json", "secrets.json", "secret.yaml", "secrets.yaml", "secret.yml", "secrets.yml", "credentials.json", "serviceaccount*.json"]
    private static let ignoreTemplate = "# Dependencies\nnode_modules/\n\n# Build output\ndist/\nbuild/\ncoverage/\n\n# Environment and keys\n" + secretPatterns.joined(separator: "\n") + "\n\n# OS\n.DS_Store\nThumbs.db\n"
    /// Names only, using the existing scanner's private credential-name rule.
    /// No credential file is opened, parsed or returned in a preview.
    private static func exposedCredentialNames(root: URL) throws -> [String] {
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard entries.count <= 10_000 else { throw NativeRPCError(code: "fix-unavailable", message: "The folder is too large for a safe preview. Use the listed steps or ask an AI.") }
        let names = try entries.filter { url in
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true else { return false }
            let name = url.lastPathComponent
            guard BackendUsageIO.matches("\\.(example|sample|template|dist|defaults?)$", name, insensitive: true).isEmpty else { return false }
            return !BackendUsageIO.matches("^(\\.env(\\.[^/]+)?|[^/]+\\.(pem|p12|pfx|jks|keystore)|id_(rsa|dsa|ecdsa|ed25519)|\\.netrc|\\.pgpass|secrets?\\.(json|ya?ml)|credentials\\.json|serviceaccount[^/]*\\.json)$", name, insensitive: true).isEmpty
        }.map(\.lastPathComponent).sorted()
        guard names.allSatisfy({ !$0.contains("\n") && !$0.contains("\r") && !$0.contains("\0") }) else {
            throw NativeRPCError(code: "fix-unavailable", message: "A credential filename cannot be represented safely in an ignore rule. Use the listed steps or ask an AI.")
        }
        return names
    }
    private static func anchored(_ name: String) -> String {
        "/" + name.map { "\\*?[] ".contains($0) ? "\\" + String($0) : String($0) }.joined()
    }
    private static func unescape(_ value: String) -> String {
        var result = "", escaped = false
        for char in value {
            if escaped { result.append(char); escaped = false }
            else if char == "\\" { escaped = true }
            else { result.append(char) }
        }
        if escaped { result.append("\\") }; return result
    }
    private static func instructions(_ file: String) -> String {
        "# \(file)\n\nInstructions for an AI agent working in this repository.\n\n## What this is\n\n<!-- One paragraph: what the project does and who it is for. -->\n\n## Run it\n\n```sh\n# install\n# start\n```\n\n## Test it\n\n```sh\n# the exact command that proves a change is sound\n```\n\n## Layout\n\n<!-- The three or four directories that matter, and what lives in each. -->\n\n## Conventions\n\n<!-- Style, naming and patterns you actually enforce in review. -->\n\n## Do not\n\n<!-- Files, directories or commands an agent must leave alone. -->\n"
    }
    private static func covers(_ ignore: BackendFilesystemIgnore, _ path: String, directory: Bool) -> Bool {
        let segments = path.split(separator: "/").map(String.init)
        for index in segments.indices {
            let final = index == segments.count - 1, partial = segments[...index].joined(separator: "/")
            var covered = false
            for rule in ignore.rules where !rule.directoryOnly || !final || directory {
                if rule.matches(partial, directory: !final || directory) { covered = !rule.negated }
            }
            if covered { return true }
        }
        return false
    }
}
