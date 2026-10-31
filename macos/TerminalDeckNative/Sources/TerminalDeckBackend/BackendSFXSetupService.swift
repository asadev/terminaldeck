import Foundation
import CryptoKit
import Darwin
import TerminalDeckNativeCore

/// A short-lived review over the engine's real init plan. Detected projects use
/// the existing init writer. A person can explicitly choose one command when
/// detection cannot cover their product; only that narrow fallback writes JSON.
public actor BackendSFXSetupService {
    public typealias Plan = @Sendable (String, Bool) async throws -> NativeRPCValue
    public typealias Setup = @Sendable (String) async throws -> NativeRPCValue
    private let plan: Plan, setup: Setup
    private let now: @Sendable () -> Double
    private struct Pending: Sendable {
        let root: String, config: URL, text: String, command: String?, fingerprint: String
        let ignore: Data?, deadline: Double
        var resuming = false
    }
    private var pending: [String: Pending] = [:]
    private var applying: Set<String> = []
    public init(plan: @escaping Plan, setup: @escaping Setup,
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.plan = plan; self.setup = setup; self.now = now
    }

    public func preview(_ project: String, checkCommand: String? = nil, prepareRuntime: Bool = false) async throws -> NativeRPCValue {
        let root = try root(project), command = try command(checkCommand)
        guard !applying.contains(root) else { throw problem("Setup is still finishing. Wait for its result, then try again.") }
        let raw: NativeRPCValue
        do { raw = try await plan(root, prepareRuntime) }
        catch let missing as BackendStaysFixedNotDownloaded {
            return object([("summary", .string("Prepare Stays Fixed, then review what it can check.")), ("prepareNeeded", .bool(true)), ("preparation", .string(missing.note)), ("canApply", .bool(false)), ("checkCommand", command.map(NativeRPCValue.string) ?? .null), ("problem", .null)])
        }
        try Task.checkCancellation()
        var candidate = try candidate(raw, root: root, command: command)
        let readiness = BackendStaysFixedRead.readiness(object([("plan", raw)]), plan: true)
        let already = BackendStaysFixedWhere.config(root) != nil || raw["config"]["exists"].bool == true
        let hasGit = BackendStaysFixedWhere.git(root)
        let hasCoverage = !(readiness["ready"].elements ?? []).isEmpty
        let ignore = try ignoreSnapshot(root)
        let needsFinish = already && expectedIgnore(ignore, root: root) != ignore
        if already, let relative = BackendStaysFixedWhere.config(root) {
            let existing = URL(fileURLWithPath: root).appendingPathComponent(relative)
            try noLink(existing)
            let data = try Data(contentsOf: existing)
            guard data.count <= 512 * 1024, let text = String(data: data, encoding: .utf8) else { throw problem("The existing settings cannot be read as text. Restore the settings from Git, then open Stays Fixed again.") }
            candidate = (existing, text, candidate.fingerprint)
        }
        let canApply = hasGit && (needsFinish || (!already && (hasCoverage || command != nil)))
        var issue: String?
        if !hasGit { issue = "This project needs Git so Stays Fixed can keep a build to compare. Set up Git in this project, then preview again." }
        else if needsFinish { issue = "Your settings are saved. Use Finish setup to add the remaining ignore lines; the saved settings stay as they are." }
        else if already { issue = "This project already has settings. Run a check to see what they cover. Setup leaves those settings as they are." }
        else if !hasCoverage && command == nil { issue = "No runnable product was detected. Add one local help or test command, then preview it. The first check will prove whether it can run." }
        let missingIgnore = Self.ignoreLines.dropFirst().filter { line in
            (ignore != nil || FileManager.default.fileExists(atPath: root + "/.git")) &&
            !(String(data: ignore ?? Data(), encoding: .utf8) ?? "").contains(line)
        }
        let token = UUID().uuidString.lowercased()
        pending = pending.filter { $0.value.deadline > now() && $0.value.root != root }
        if canApply {
            var review = Pending(root: root, config: candidate.file, text: candidate.text, command: already ? nil : command,
                                 fingerprint: candidate.fingerprint, ignore: ignore, deadline: now() + 600_000)
            review.resuming = needsFinish; pending[token] = review
        }
        var files: [NativeRPCValue] = [object([("path", .string(candidate.file.path)), ("action", .string(already ? "keep" : "create")), ("summary", .string(already ? "Keep your existing settings." : command == nil ? "Use the settings detected by the bundled engine." : "Check only the command you chose; no settings to edit by hand."))])]
        if !missingIgnore.isEmpty {
            files.append(object([("path", .string(root + "/.gitignore")), ("action", .string(ignore == nil ? "create" : "append")), ("summary", .string("Add missing ignore lines for temporary check evidence. Existing lines stay as they are."))]))
        }
        let products = (raw["project"]["products"].elements ?? []).map { item in
            object([("name", item["name"]), ("kind", item["kind"]), ("evidence", item["evidence"])])
        }
        var notHere = readiness["notHere"].elements ?? []
        if command != nil { notHere.append(.string("Native screens and other commands are not checked by this command setup. Swift internals and its outbound connections are not intercepted.")) }
        let summary = needsFinish ? "Finish setup by keeping the saved settings and adding the remaining temporary-evidence ignore lines." : command == nil ? raw["summary"].string ?? "Review the detected settings before setup." : "This setup compares the chosen command's output, exit status and file changes. Run the first check before calling it ready."
        return object([("token", canApply ? .string(token) : .null), ("summary", .string(summary)), ("configFile", .string(candidate.file.path)), ("configText", .string(candidate.text)), ("files", .array(files)), ("products", .array(products)), ("ready", command == nil ? readiness["ready"] : .array([])), ("gaps", readiness["gaps"]), ("notHere", .array(notHere)), ("canApply", .bool(canApply)), ("alreadySetUp", .bool(already)), ("prepareNeeded", .bool(false)), ("preparation", .string("")), ("problem", issue.map(NativeRPCValue.string) ?? .null), ("commandNeeded", .bool(!already && !hasCoverage)), ("checkCommand", command.map(NativeRPCValue.string) ?? .null), ("commandExplanation", .string("The first check runs this command twice in temporary project copies. Choose a local help or test command that does not use live accounts or services.")), ("partialSetup", .bool(needsFinish)), ("retryToken", needsFinish && canApply ? .string(token) : .null)])
    }

    /// The shared MCP approval path displays the same command and files the
    /// person reviewed. A client-supplied 'approved' flag is never consulted.
    public func approvalSummary(_ project: String, token: String) throws -> String {
        let root = try root(project)
        guard let approved = pending[token], approved.root == root, approved.deadline > now() else {
            throw problem("Preview this project again before approving setup.")
        }
        let command = approved.command.map { " The first check will run this command twice in temporary copies: \($0)." } ?? " Use the detected defaults shown in the preview."
        return "\(approved.resuming ? "Finish" : "Set up") Stays Fixed in \(root): \(approved.resuming ? "keep" : "create") \(approved.config.lastPathComponent) and add missing temporary-evidence lines to .gitignore. Existing settings will never be overwritten." + command
    }

    public func apply(_ project: String, token: String) async throws -> NativeRPCValue {
        let root = try root(project)
        guard let approved = pending.removeValue(forKey: token), approved.root == root, approved.deadline > now() else {
            throw problem("That setup preview has expired or belongs to another project. Preview this project again before setting it up.")
        }
        guard !applying.contains(root) else { throw problem("Setup is already running for this project. Wait for its result.") }
        applying.insert(root); defer { applying.remove(root) }
        try Task.checkCancellation()
        try unchanged(approved)
        if !approved.resuming {
            let current = try candidate(await plan(root, false), root: root, command: approved.command)
            guard current.fingerprint == approved.fingerprint else {
                throw problem("The detected settings changed since your preview. Preview again so you can review the new settings. Nothing was written.")
            }
        }
        try Task.checkCancellation()
        try unchanged(approved)
        if approved.command != nil && !approved.resuming { try createExclusive(approved.config, text: approved.text) }
        let outcome: NativeRPCValue
        do { outcome = try await setup(root) }
        catch {
            return try partialFailure(approved, token: token, wrote: [], detail: error.localizedDescription)
        }
        guard outcome["ok"].bool == true else {
            return try partialFailure(approved, token: token, wrote: outcome["wrote"].elements ?? [], detail: outcome["problem"].string ?? "The engine could not finish setup.")
        }
        let actual = try? Data(contentsOf: approved.config)
        guard actual == Data(approved.text.utf8) else {
            return object([("ok", .bool(false)), ("wrote", outcome["wrote"]), ("problem", .string("Setup finished with settings that differ from the preview. Run the preview again and inspect the settings before checking. This project has not been marked ready."))])
        }
        guard try ignoreSnapshot(root) == expectedIgnore(approved.ignore, root: root) else {
            return try partialFailure(approved, token: token, wrote: outcome["wrote"].elements ?? [], detail: "The temporary-evidence ignore lines were not fully saved.")
        }
        var wrote = outcome["wrote"].elements ?? []
        if approved.command != nil, !wrote.contains(.string(approved.config.lastPathComponent)), !wrote.contains(.string(approved.config.path)) { wrote.insert(.string(approved.config.lastPathComponent), at: 0) }
        return outcome.setting("wrote", .array(wrote)).setting("next", .string("Run the first check. Review its result, then mark that build as good."))
    }

    private func root(_ project: String) throws -> String {
        let path = try BackendStaysFixedWhere.folder(.string(project))
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
    private func command(_ command: String?) throws -> String? {
        guard let command else { return nil }
        let clean = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return nil }
        guard clean.utf8.count <= 2048, !clean.contains("\0"), !clean.contains("\n"), !clean.contains("\r") else {
            throw problem("Enter one command on one line, up to 2,048 characters, then preview it again.")
        }
        return clean
    }
    private func candidate(_ raw: NativeRPCValue, root: String, command: String?) throws -> (file: URL, text: String, fingerprint: String) {
        guard raw["root"].string.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) == root,
              let engineText = raw["config"]["text"].string, !engineText.isEmpty, engineText.utf8.count <= 512 * 1024,
              let engineFile = raw["config"]["file"].string else {
            throw problem("The engine did not return settings for this project folder. Open the folder that owns the existing settings, then preview again.")
        }
        let proposed = URL(fileURLWithPath: command == nil ? engineFile : root + "/staysfixed.config.json").standardizedFileURL
        try noLink(proposed)
        let file = proposed.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(proposed.lastPathComponent).standardizedFileURL
        let relative = file.path.hasPrefix(root + "/") ? String(file.path.dropFirst(root.count + 1)) : ""
        guard BackendStaysFixedWhere.configNames.contains(relative), file.resolvingSymlinksInPath().path.hasPrefix(root + "/") else {
            throw problem("Setup proposed settings outside this project. Choose this project's own folder and preview again.")
        }
        let text: String
        if let command {
            let settings = object([("product", .string(URL(fileURLWithPath: root).lastPathComponent)), ("source", object([("folders", .array([.string(".")]))])), ("process", object([("commands", .array([object([("name", .string("Chosen command")), ("run", .string(command)), ("describe", .string("Compare the output, exit status and files of the command chosen in Terminal Deck.")), ("timeoutMs", .number(120_000))])]))]))])
            text = String(decoding: try settings.encodedJSON(pretty: true), as: UTF8.self) + "\n"
        } else { text = engineText }
        // Coverage and the command are part of the approval, as well as bytes.
        let sealed = object([("file", .string(file.path)), ("text", .string(text)), ("covers", raw["covers"]), ("readiness", raw["readiness"]), ("command", command.map(NativeRPCValue.string) ?? .null)])
        let fingerprint = SHA256.hash(data: try sealed.encodedJSON()).map { String(format: "%02x", $0) }.joined()
        return (file, text, fingerprint)
    }
    private func unchanged(_ approved: Pending) throws {
        guard BackendStaysFixedWhere.git(approved.root) else { throw problem("This project no longer has Git. Set up Git and preview again. Nothing was written.") }
        if approved.resuming {
            guard BackendStaysFixedWhere.config(approved.root).map({ URL(fileURLWithPath: approved.root).appendingPathComponent($0).path }) == approved.config.path,
                  (try? Data(contentsOf: approved.config)) == Data(approved.text.utf8) else {
                throw problem("The settings changed after the partial setup. Finish setup will keep them and cannot reuse that preview. Run a check with the saved settings or preview again.")
            }
        } else {
            guard BackendStaysFixedWhere.config(approved.root) == nil else { throw problem("Settings appeared after your preview. Setup will keep them. Run a check or preview again; nothing was overwritten.") }
        }
        for relative in BackendStaysFixedWhere.configNames { try noLink(URL(fileURLWithPath: approved.root).appendingPathComponent(relative)) }
        guard try ignoreSnapshot(approved.root) == approved.ignore else { throw problem("The project's ignore file changed after your preview. Preview again before setup. Nothing was written.") }
    }
    private func noLink(_ file: URL) throws {
        var info = stat()
        if lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
            throw problem("Setup found a linked settings or ignore file. Replace the link with a local file in this project, then preview again.")
        }
    }
    private func ignoreSnapshot(_ root: String) throws -> Data? {
        let file = URL(fileURLWithPath: root).appendingPathComponent(".gitignore")
        try noLink(file)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard properties.isRegularFile == true, (properties.fileSize ?? Int.max) <= 512 * 1024 else { throw problem("The project's ignore file cannot be safely updated. Keep it as a regular text file under 512 KB, then preview again.") }
        let data = try Data(contentsOf: file)
        guard String(data: data, encoding: .utf8) != nil else { throw problem("The project's ignore file is not UTF-8 text. Save it as UTF-8, then preview again.") }
        return data
    }
    private func createExclusive(_ file: URL, text: String) throws {
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard descriptor >= 0 else { throw problem("Command settings could not be created. A file may have appeared since the preview. Preview again; existing settings were not overwritten.") }
        var complete = false
        defer {
            if !complete {
                var opened = stat(), current = stat()
                if fstat(descriptor, &opened) == 0, lstat(file.path, &current) == 0,
                   opened.st_dev == current.st_dev, opened.st_ino == current.st_ino { _ = unlink(file.path) }
            }
            close(descriptor)
        }
        let data = Data(text.utf8)
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var sent = 0
            while sent < buffer.count {
                let count = write(descriptor, base.advanced(by: sent), buffer.count - sent)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw problem("The settings could not be fully written. Check free disk space, then preview again.") }
                sent += count
            }
        }
        guard fsync(descriptor) == 0 else { throw problem("The settings could not be saved to disk. Check free disk space, then preview again.") }
        complete = true
    }
    private func expectedIgnore(_ original: Data?, root: String) -> Data? {
        if original == nil && !FileManager.default.fileExists(atPath: root + "/.git") { return nil }
        let text = String(data: original ?? Data(), encoding: .utf8) ?? ""
        let missing = Self.ignoreLines.dropFirst().filter { !text.contains($0) }
        guard !missing.isEmpty else { return original }
        let prefix = text.isEmpty || text.hasSuffix("\n") ? "" : "\n"
        return Data((text + prefix + "\n" + Self.ignoreLines[0] + "\n" + missing.joined(separator: "\n") + "\n").utf8)
    }
    private func partialFailure(_ approved: Pending, token: String, wrote: [NativeRPCValue], detail: String) throws -> NativeRPCValue {
        guard (try? Data(contentsOf: approved.config)) == Data(approved.text.utf8) else {
            return object([("ok", .bool(false)), ("wrote", .array(wrote)), ("problem", .string(detail + " Preview setup again before checking."))])
        }
        let ignore = try ignoreSnapshot(approved.root)
        var retry = Pending(root: approved.root, config: approved.config, text: approved.text, command: approved.command, fingerprint: approved.fingerprint, ignore: ignore, deadline: now() + 600_000)
        retry.resuming = true; pending[token] = retry
        let files = wrote.contains(.string(approved.config.lastPathComponent)) ? wrote : [.string(approved.config.lastPathComponent)] + wrote
        return object([("ok", .bool(false)), ("wrote", .array(files)), ("problem", .string("The reviewed settings are saved, but setup did not finish. " + detail + " Use Finish setup to retry the remaining step; your settings will stay as they are.")), ("partialSetup", .bool(true)), ("retryToken", .string(token))])
    }
    private func object(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendStaysFixedRead.object(pairs) }
    private func problem(_ message: String) -> NativeRPCError { NativeRPCError(code: "setup-needs-review", message: message) }
    /// Bundled 0.15.0 core/paths.js. The engine performs the actual update.
    private static let ignoreLines = ["# Stays Fixed — evidence from the last run, not the promise", ".staysfixed/results/", ".staysfixed/report.html", ".staysfixed/watch-window.json", ".staysfixed/v2/builds/", ".staysfixed/v2/last-check.json", ".staysfixed/**/*.lock"]
}
