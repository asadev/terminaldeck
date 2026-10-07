import Foundation
import TerminalDeckNativeCore

/// hooks.ts, ported. JSON hook groups are edited only by explicit owner actions and the boot repair pass. This
/// preserves unknown settings, foreign hook entries and matcher-group fields. Installing never writes Codex's
/// trusted_hash; that review remains inside the CLI.
public actor BackendSessionHookInstallation {
    public struct Status: Sendable {
        public let id: String
        public let file: String
        public let fileExists: Bool
        public let state: String
        public let installedEvents: [String]
        public let staleEvents: [String]
        public let missingEvents: [String]
        public let foreignHooks: Int
        public let foreignOwners: [String]
        public let backupPath: String?
        public let message: String
        func withMessage(_ text: String) -> Status {
            Status(id: id, file: file, fileExists: fileExists, state: state, installedEvents: installedEvents, staleEvents: staleEvents, missingEvents: missingEvents,
                   foreignHooks: foreignHooks, foreignOwners: foreignOwners, backupPath: backupPath, message: text)
        }
        public var wireValue: NativeRPCValue {
            .object([.init("id", .string(id)), .init("label", .string(BackendAccountProfile.providerLabel(id))), .init("file", .string(file)),
                .init("fileExists", .bool(fileExists)), .init("state", .string(state)), .init("installedEvents", .array(installedEvents.map(NativeRPCValue.string))),
                .init("staleEvents", .array(staleEvents.map(NativeRPCValue.string))), .init("missingEvents", .array(missingEvents.map(NativeRPCValue.string))),
                .init("foreignHooks", .number(Double(foreignHooks))), .init("foreignOwners", .array(foreignOwners.map(NativeRPCValue.string))),
                .init("backupPath", backupPath.map(NativeRPCValue.string) ?? .null), .init("message", .string(message))])
        }
    }
    public static let events: [String: [String]] = [
        "claude": ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "Notification", "Stop", "StopFailure", "SessionEnd"],
        "codex": ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"],
        "gemini": ["SessionStart", "BeforeAgent", "BeforeTool", "AfterTool", "AfterAgent", "Notification", "SessionEnd"],
    ]
    /// hooks.ts `HOOK_PROVIDERS.codex.requirement`, word for word.
    public static let codexRequirement = "Codex needs `hooks = true` in ~/.codex/config.toml [features], then Trust all once when it asks."
    /// hooks.ts `HOOK_PROVIDERS[id].requirement`: the step a press cannot take for the person (only Codex has one).
    static func requirement(_ provider: String) -> String? { provider == "codex" ? codexRequirement : nil }
    /// hook-server.ts `CONFIG_FILE`: the file name every copy's `-K` path ends in.
    static let endpointConfigFile = "hook-endpoint.conf"
    private let configuration: BackendAccountConfiguration
    private let endpoint: BackendSessionHookEndpoint
    private let files: [String: URL]
    private let offerFile: URL
    private let authorize: @Sendable (NativeRPCContext) throws -> Void
    public init(configuration: BackendAccountConfiguration, endpoint: BackendSessionHookEndpoint,
                providerSettingsFiles: [String: URL], offerFile: URL,
                authorizeMutation: @escaping @Sendable (NativeRPCContext) throws -> Void) throws {
        guard Set(providerSettingsFiles.keys) == Set(Self.events.keys), providerSettingsFiles.values.allSatisfy({ $0.isFileURL && $0.path.hasPrefix("/") }),
              offerFile.isFileURL, offerFile.path.hasPrefix("/") else { throw BackendSessionFailure.invalidInput("Hook settings paths must come from trusted account assembly.") }
        self.configuration = configuration; self.endpoint = endpoint; files = providerSettingsFiles; self.offerFile = offerFile; authorize = authorizeMutation
    }

    // MARK: file access (hooks.ts `loadSettings`, `serialise`, `writeAtomic`, `backupOnce`)

    /// hooks.ts `LoadedSettings`.
    private struct Settings {
        let data: NativeRPCValue
        let exists: Bool
        /// Permission bits to write back, so a 0600 config stays 0600.
        let mode: mode_t
        let indent: String
        let trailingNewline: Bool
    }
    /// hooks.ts `SettingsError`: the rest of a sentence that starts with the file's path.
    private struct SettingsRefusal: Error { let detail: String }
    /// hooks.ts `HookWriteResult` minus `ok`: a refusal throws instead.
    private struct WriteResult { let message: String; let status: Status }
    private static let readLimit = 8 * 1024 * 1024
    /// hooks.ts `NEW_FILE_MODE`: a config we are about to hold a token in defaults to owner-only.
    private static let newFileMode: mode_t = 0o600

    private func settingsFile(_ provider: String) throws -> URL {
        guard Self.events[provider] != nil, let file = files[provider] else { throw BackendSessionFailure.unsupported("No trusted hook settings path was supplied for this provider.") }
        return file
    }
    /// hooks.ts `detectIndent`: the indent the file already uses, so writing back does not reformat it.
    static func detectIndent(_ text: String) -> String {
        guard let found = text.range(of: #"\n[ \t]+""#, options: .regularExpression) else { return "  " }
        return String(String.UnicodeScalarView(text[found].unicodeScalars.dropFirst().dropLast()))
    }
    private static func mode(of file: URL) -> mode_t {
        var info = stat()
        return stat(file.path, &info) == 0 ? info.st_mode & 0o777 : newFileMode
    }
    private func loadSettings(_ provider: String) throws -> Settings {
        let target = try settingsFile(provider).resolvingSymlinksInPath()
        let bytes: Data?
        do { bytes = try BackendAccountFiles.boundedRead(target, maximum: Self.readLimit) } catch { throw SettingsRefusal(detail: "could not be read: \(error.localizedDescription)") }
        guard let bytes else { return Settings(data: .object([]), exists: false, mode: Self.newFileMode, indent: "  ", trailingNewline: true) }
        let mode = Self.mode(of: target), text = String(decoding: bytes, as: UTF8.self)
        // An empty file is a fresh start, not a parse failure.
        if text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))).isEmpty {
            return Settings(data: .object([]), exists: true, mode: mode, indent: "  ", trailingNewline: true)
        }
        let parsed: NativeRPCValue
        // Comments, a trailing comma, a half-written edit: not understood well enough to rewrite without loss.
        do { parsed = try NativeRPCValue.parseJSON(bytes) } catch { throw SettingsRefusal(detail: "is not valid JSON (\(error.localizedDescription)), so it was left untouched") }
        guard parsed.fields != nil else { throw SettingsRefusal(detail: "is not a JSON object, so it was left untouched") }
        return Settings(data: parsed, exists: true, mode: mode, indent: Self.detectIndent(text), trailingNewline: bytes.last == 0x0A)
    }
    /// hooks.ts `serialise`: `JSON.stringify(data, null, indent)` plus the trailing newline the file had.
    /// The two-space writer's leading runs are structural only (strings never hold a raw newline), so re-indenting
    /// line by line is exact.
    private static func serialise(_ settings: Settings, _ data: NativeRPCValue) throws -> Data {
        let pretty = String(decoding: try data.encodedJSON(pretty: true), as: UTF8.self), indent = String(settings.indent.unicodeScalars.prefix(10))
        let body = indent == "  " ? pretty : pretty.components(separatedBy: "\n").map { line in
            let spaces = line.unicodeScalars.prefix(while: { $0 == " " }).count
            return String(repeating: indent, count: spaces / 2) + String(String.UnicodeScalarView(line.unicodeScalars.dropFirst(spaces)))
        }.joined(separator: "\n")
        return Data((settings.trailingNewline ? body + "\n" : body).utf8)
    }
    /// hooks.ts `writeAtomic`: the resolved target, so a dotfiles symlink stays a symlink, then the mode it had.
    private func writeSettings(_ data: Data, mode: mode_t, to target: URL) throws {
        try BackendAccountFiles.writeAtomic(data, to: target)
        if mode != Self.newFileMode { _ = chmod(target.path, mode) }
    }
    private func backup(_ provider: String) -> URL { configuration.dataDirectory.appendingPathComponent("hook/backups").appendingPathComponent(provider + "-settings.json") }
    private func existingBackup(_ provider: String) -> String? { FileManager.default.fileExists(atPath: backup(provider).path) ? backup(provider).path : nil }
    /// hooks.ts `backupOnce`: the pristine copy, taken before the first write and never again.
    private func backupOnce(_ provider: String, from target: URL) throws -> URL? {
        let copy = backup(provider)
        if FileManager.default.fileExists(atPath: copy.path) { return copy }
        // No source file yet: there is nothing to preserve.
        guard let bytes = try BackendAccountFiles.boundedRead(target, maximum: Self.readLimit) else { return nil }
        try BackendAccountFiles.writeAtomic(bytes, to: copy)
        return copy
    }

    // MARK: hook structure (hooks.ts `isOurs` … `applyRemove`)

    private var marker: String { "# " + endpoint.appID + "-hook" }
    /// hooks.ts `isOurs`: the single test for ownership.
    private func ours(_ entry: NativeRPCValue) -> Bool { entry.fields != nil && entry["command"].string?.contains(marker) == true }
    /// hooks.ts `ownerOf` (`FOREIGN_MARKER_RE`): whose hook is this, if it announces itself the way ours does?
    static func owner(of entry: NativeRPCValue) -> String? {
        guard entry.fields != nil, let command = entry["command"].string,
              let pattern = try? NSRegularExpression(pattern: #"#\s*([a-z][a-z0-9_-]*)-hook\b"#, options: [.caseInsensitive]),
              let match = pattern.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              let name = Range(match.range(at: 1), in: command) else { return nil }
        return command[name].lowercased()
    }
    /// hooks.ts `eventEntries`: only array values are events; Gemini keeps settings beside them.
    private static func eventEntries(_ hooks: NativeRPCValue) -> [(key: String, groups: [NativeRPCValue])] {
        (hooks.fields ?? []).compactMap { field in field.value.elements.map { (field.key, $0) } }
    }
    /// hooks.ts `hooksObject`.
    private static func hooksObject(_ data: NativeRPCValue) throws -> NativeRPCValue {
        let existing = data["hooks"]
        if existing == .missing { return .object([]) }
        guard existing.fields != nil else { throw SettingsRefusal(detail: "has a `hooks` key that is not an object, so it was left untouched") }
        return existing
    }
    /// hooks.ts `ourEntriesByEvent`, in file order.
    private func ourEntriesByEvent(_ hooks: NativeRPCValue) -> [(event: String, entries: [NativeRPCValue])] {
        Self.eventEntries(hooks).compactMap { event, groups in
            let entries = groups.flatMap { group -> [NativeRPCValue] in
                guard group.fields != nil, let list = group["hooks"].elements else { return [] }
                return list.filter { ours($0) }
            }
            return entries.isEmpty ? nil : (event, entries)
        }
    }
    /// hooks.ts `surveyForeign`: everything that is somebody else's, counted and attributed.
    private func surveyForeign(_ hooks: NativeRPCValue) -> (count: Int, owners: [String]) {
        var count = 0, owners = Set<String>()
        for (_, groups) in Self.eventEntries(hooks) {
            for group in groups {
                guard group.fields != nil, let entries = group["hooks"].elements else { continue }
                for entry in entries where entry.fields != nil && !ours(entry) {
                    count += 1
                    if let owner = Self.owner(of: entry) { owners.insert(owner) }
                }
            }
        }
        return (count, owners.sorted())
    }
    /// hooks.ts `buildEntry`.
    private func buildEntry(provider: String, event: String) -> NativeRPCValue {
        var entry = NativeRPCValue.object([.init("type", .string("command")), .init("command", .string(command(provider: provider, event: event)))])
        if provider == "claude" { entry = entry.setting("timeout", .number(5)) }
        if provider == "gemini" { entry = entry.setting("timeout", .number(5000)).setting("name", .string(endpoint.appID + "-hook")).setting("description", .string(configuration.appName + " session tracking")) }
        return entry
    }
    /// hooks.ts `stripOurs`: a group that arrived empty is kept; one we emptied is dropped.
    private func stripOurs(_ groups: [NativeRPCValue]) -> (groups: [NativeRPCValue], removed: Int) {
        var removed = 0, out: [NativeRPCValue] = []
        for group in groups {
            guard group.fields != nil, let entries = group["hooks"].elements else { out.append(group); continue }
            let kept = entries.filter { !ours($0) }, dropped = entries.count - kept.count
            removed += dropped
            if dropped == 0 { out.append(group); continue }
            if kept.isEmpty { continue }
            out.append(group.setting("hooks", .array(kept)))
        }
        return (out, removed)
    }
    /// hooks.ts `applyInstall`: our hooks replaced for one provider, everything else exactly as found.
    private func applyInstall(_ data: NativeRPCValue, provider: String) throws -> NativeRPCValue {
        let spec = Self.events[provider] ?? []
        var next = try Self.hooksObject(data)
        for (event, groups) in Self.eventEntries(next) {
            let kept = stripOurs(groups)
            guard kept.removed > 0 else { continue }
            next = kept.groups.isEmpty && !spec.contains(event) ? next.removing(event) : next.setting(event, .array(kept.groups))
        }
        for event in spec {
            let existing = next[event]
            if existing != .missing, existing.elements == nil { throw SettingsRefusal(detail: "has a `hooks.\(event)` that is not an array, so it was left untouched") }
            let group = NativeRPCValue.object([.init("matcher", .string("")), .init("hooks", .array([buildEntry(provider: provider, event: event)]))])
            next = next.setting(event, .array((existing.elements ?? []) + [group]))
        }
        return data.setting("hooks", next)
    }
    /// hooks.ts `applyRemove`: every trace of us, and nothing else.
    private func applyRemove(_ data: NativeRPCValue) throws -> (data: NativeRPCValue, removed: Int) {
        let hooks = try Self.hooksObject(data)
        var next = hooks, removed = 0
        for (event, groups) in Self.eventEntries(hooks) {
            let result = stripOurs(groups)
            guard result.removed > 0 else { continue }
            removed += result.removed
            next = result.groups.isEmpty ? next.removing(event) : next.setting(event, .array(result.groups))
        }
        if removed == 0 { return (data, 0) }
        return ((next.fields ?? []).isEmpty ? data.removing("hooks") : data.setting("hooks", next), removed)
    }

    // MARK: status (hooks.ts `readStatus`, `describe`)

    private static func detail(_ error: Error) -> String { (error as? SettingsRefusal)?.detail ?? error.localizedDescription }
    /// hooks.ts `describe`. Says nothing about other tools' hooks: the panel renders those from their own fields.
    private static func describe(_ events: [String], state: String, fileExists: Bool, staleCount: Int) -> String {
        switch state {
        case "complete": return "All \(events.count) events are installed and pointing at this run."
        case "stale": return "Installed, but \(staleCount) event\(staleCount == 1 ? "" : "s") point somewhere other than this copy of the app. Reinstall to aim them here."
        case "partial": return "Only some events are installed, so parts of a session go unreported."
        default: return fileExists ? "No hooks from this app in this file yet." : "This file does not exist yet; installing creates it."
        }
    }
    public func status(_ provider: String) -> Status {
        guard let spec = Self.events[provider], let file = files[provider] else {
            return Status(id: provider, file: "", fileExists: false, state: "error", installedEvents: [], staleEvents: [], missingEvents: [], foreignHooks: 0, foreignOwners: [],
                backupPath: nil, message: "No trusted hook settings path was supplied for this provider.")
        }
        let settings: Settings, hooks: NativeRPCValue
        do { settings = try loadSettings(provider); hooks = try Self.hooksObject(settings.data) } catch {
            // hooks.ts `errorStatus`.
            return Status(id: provider, file: file.path, fileExists: true, state: "error", installedEvents: [], staleEvents: [], missingEvents: spec, foreignHooks: 0,
                foreignOwners: [], backupPath: existingBackup(provider), message: file.path + " " + Self.detail(error))
        }
        let owned = ourEntriesByEvent(hooks), foreign = surveyForeign(hooks)
        var installed: [String] = [], stale: [String] = [], missing: [String] = []
        for event in spec {
            guard let entries = owned.first(where: { $0.event == event })?.entries, !entries.isEmpty else { missing.append(event); continue }
            // Byte-for-byte against the command this copy would write today.
            let expected = command(provider: provider, event: event)
            if entries.contains(where: { $0["command"].string == expected }) { installed.append(event) } else { stale.append(event) }
        }
        // Events an earlier version installed and this one no longer manages: ours for removal, not for health.
        let orphaned = owned.map(\.event).filter { !spec.contains($0) }
        let state = installed.count == spec.count ? "complete"
            : !stale.isEmpty && installed.count + stale.count == spec.count ? "stale"
            : installed.count + stale.count == 0 && orphaned.isEmpty ? "none" : "partial"
        return Status(id: provider, file: file.path, fileExists: settings.exists, state: state, installedEvents: installed, staleEvents: stale,
            missingEvents: missing, foreignHooks: foreign.count, foreignOwners: foreign.owners, backupPath: existingBackup(provider),
            message: Self.describe(spec, state: state, fileExists: settings.exists, staleCount: stale.count))
    }
    public func allStatus() -> [Status] { BackendAccountProfile.signInProviders.filter { files[$0] != nil }.map(status) }
    public func command(provider: String, event: String) -> String {
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let keep = ["SessionStart", "UserPromptSubmit", "PostToolUse", "BeforeAgent", "AfterTool"].contains(event)
        return "/usr/bin/curl -s \(keep ? "" : "-o /dev/null ")--connect-timeout 1 --max-time 3 -X POST -H 'content-type: application/json' -H \"x-\(endpoint.appID)-session: $\(endpoint.sessionEnvironment)\" -K \(quoted(endpoint.configPath)) --data-binary @- \(quoted("http://localhost/hook/\(provider)/\(event)")) 2>/dev/null || true \(marker)"
    }

    // MARK: install / remove (hooks.ts `installHooks`, `removeHooks`)

    /// A test copy of the app (Info.plist `TDAgentConfigReadOnly`) never writes the
    /// person's own ~/.claude, ~/.codex or ~/.gemini: their running app owns those hooks.
    static var agentConfigReadOnly: Bool {
        Bundle.main.object(forInfoDictionaryKey: "TDAgentConfigReadOnly") as? Bool == true
            || ProcessInfo.processInfo.environment["TD_AGENT_CONFIG_READONLY"] == "1"
    }
    private func refuseTestCopyWrite() throws {
        if Self.agentConfigReadOnly {
            throw BackendSessionFailure.unsupported("This is a test copy of the app: it leaves your agents' hook settings to your running Terminal Deck.")
        }
    }
    private func performInstall(_ provider: String) throws -> WriteResult {
        try refuseTestCopyWrite()
        let file = try settingsFile(provider), spec = Self.events[provider] ?? []
        let settings: Settings, next: NativeRPCValue
        do { settings = try loadSettings(provider); next = try applyInstall(settings.data, provider: provider) }
        catch { throw BackendSessionFailure.invalidInput(file.path + " " + Self.detail(error)) }
        let target = file.resolvingSymlinksInPath()
        let backup = try settings.exists ? backupOnce(provider, from: target) : nil
        try writeSettings(Self.serialise(settings, next), mode: settings.mode, to: target)
        let current = status(provider)
        // Codex's install repairs the deprecated feature flag in the same press.
        let migrated = try provider == "codex" ? migrateCodexFeatureFlag() : ""
        let note = backup.map { " The original was kept at \($0.path)." } ?? ""
        let flagNote = migrated.isEmpty ? "" : " " + migrated, requirement = Self.requirement(provider).map { " " + $0 } ?? ""
        return WriteResult(message: "Installed \(spec.count) hooks into \(file.path).\(note)\(flagNote)\(requirement)", status: current)
    }
    private func performRemove(_ provider: String) throws -> WriteResult {
        try refuseTestCopyWrite()
        let file = try settingsFile(provider)
        let settings: Settings
        do { settings = try loadSettings(provider) } catch { throw BackendSessionFailure.invalidInput(file.path + " " + Self.detail(error)) }
        guard settings.exists else { return WriteResult(message: "\(file.path) does not exist — nothing to remove.", status: status(provider)) }
        let result: (data: NativeRPCValue, removed: Int)
        do { result = try applyRemove(settings.data) } catch { throw BackendSessionFailure.invalidInput(file.path + " " + Self.detail(error)) }
        // Rewriting a file to produce a byte-identical result is pure risk.
        guard result.removed > 0 else { return WriteResult(message: "No hooks from this app were in \(file.path) — it was not modified.", status: status(provider)) }
        let target = file.resolvingSymlinksInPath()
        _ = try backupOnce(provider, from: target)
        try writeSettings(Self.serialise(settings, result.data), mode: settings.mode, to: target)
        // Turning any provider off withdraws the standing consent, and settles a never-asked offer. An unwritable
        // marker leaves the old answer standing; the removal itself succeeded and is what was asked about.
        try? recordOfferAnswer("declined")
        return WriteResult(message: "Removed \(result.removed) hook\(result.removed == 1 ? "" : "s") from \(file.path). Nothing else in the file was changed.", status: status(provider))
    }
    /// The returned status carries the write's sentence as its message (the RPC answers `{ok, message, status}` from it).
    public func install(_ provider: String, context: NativeRPCContext) throws -> Status {
        try authorize(context)
        let result = try performInstall(provider)
        return result.status.withMessage(result.message)
    }
    public func remove(_ provider: String, context: NativeRPCContext) throws -> Status {
        try authorize(context)
        let result = try performRemove(provider)
        return result.status.withMessage(result.message)
    }

    // MARK: boot repair (hooks.ts `syncInstalledHooks`, `staleHooksBelongToAnotherCopy`)

    /// hooks.ts `endpointConfigsNamedIn`: the single-quoted config paths our installed commands read their token from.
    private func endpointConfigsNamed(in hooks: NativeRPCValue) -> [String] {
        guard let quoted = try? NSRegularExpression(pattern: "'([^']*" + NSRegularExpression.escapedPattern(for: Self.endpointConfigFile) + ")'") else { return [] }
        var found: [String] = []
        for (_, entries) in ourEntriesByEvent(hooks) {
            for entry in entries {
                guard let command = entry["command"].string else { continue }
                for match in quoted.matches(in: command, range: NSRange(command.startIndex..., in: command)) {
                    if let range = Range(match.range(at: 1), in: command), !found.contains(String(command[range])) { found.append(String(command[range])) }
                }
            }
        }
        return found
    }
    /// hooks.ts `staleHooksBelongToAnotherCopy`: decided from the config path in the installed command, never from
    /// a probe — a closed copy still owns its hooks.
    func staleHooksBelongToAnotherCopy(_ provider: String) -> Bool {
        let ownConfig = endpoint.configPath
        if ownConfig.isEmpty { return false }
        let named: [String]
        do { named = endpointConfigsNamed(in: try Self.hooksObject(try loadSettings(provider).data)) } catch { return true }
        // No config path at all is a command from before the token moved out of line: ours to migrate.
        if named.isEmpty { return false }
        return named.contains { $0 != ownConfig }
    }
    public func sync(context: NativeRPCContext) throws -> [Status] {
        try authorize(context)
        // The flag belongs to no copy of this app, so it is repaired even when the hooks already read complete.
        _ = try? migrateCodexFeatureFlag()
        // Standing consent from the first-run offer covers an assistant installed later.
        let standing = offerAnswer() == "accepted"
        return BackendAccountProfile.signInProviders.filter { files[$0] != nil }.map { provider in
            let current = status(provider)
            let repair = (current.state == "stale" || current.state == "partial") && !staleHooksBelongToAnotherCopy(provider)
            let covered = standing && current.state == "none" && current.fileExists
            guard repair || covered else { return current }
            // Best-effort: a refresh that fails must not stop the app starting; the panel shows the real state.
            return (try? performInstall(provider))?.status ?? status(provider)
        }
    }

    /// hooks.ts `migratedCodexFeatures`: rename the deprecated `[features] codex_hooks` key to `hooks`, as a
    /// text transform so the rest of the person's TOML is carried through byte for byte.
    static func migratedCodexFeatures(_ toml: String) -> (changed: Bool, text: String) {
        let lines = toml.components(separatedBy: "\n")
        var inFeatures = false, hasHooks = false, deprecated: [Int] = []
        for (index, line) in lines.enumerated() {
            if let match = line.range(of: #"^\s*\[\[?([^\]]*)\]?\]\s*(?:#.*)?$"#, options: .regularExpression) {
                let inner = line[match].drop(while: { $0.isWhitespace }).drop(while: { $0 == "[" })
                let name = inner.prefix(while: { $0 != "]" })
                inFeatures = name.trimmingCharacters(in: .whitespaces) == "features"
                continue
            }
            guard inFeatures else { continue }
            if line.range(of: #"^\s*(?:"hooks"|hooks)\s*="#, options: .regularExpression) != nil { hasHooks = true }
            if line.range(of: #"^\s*(?:"codex_hooks"|codex_hooks)\s*="#, options: .regularExpression) != nil { deprecated.append(index) }
        }
        guard !deprecated.isEmpty else { return (false, toml) }
        if hasHooks { return (true, lines.enumerated().filter { !deprecated.contains($0.offset) }.map(\.element).joined(separator: "\n")) }
        var out: [String] = []
        for (index, line) in lines.enumerated() {
            if index == deprecated[0] {
                out.append(line.replacingOccurrences(of: #"(^\s*)(?:"codex_hooks"|codex_hooks)(\s*=)"#, with: "$1hooks$2", options: .regularExpression))
            } else if !deprecated.contains(index) { out.append(line) }
        }
        return (true, out.joined(separator: "\n"))
    }
    /// hooks.ts `migrateCodexFeatureFlag`: run the transform on `~/.codex/config.toml` with a once-only backup under
    /// the hook backups. A sentence when something changed, empty when there was nothing to do (including no file).
    private func migrateCodexFeatureFlag() throws -> String {
        if Self.agentConfigReadOnly { return "" }
        let file = configuration.homeDirectory.appendingPathComponent(".codex/config.toml"), target = file.resolvingSymlinksInPath()
        guard let bytes = try? BackendAccountFiles.boundedRead(target, maximum: 4 * 1024 * 1024) else { return "" }
        let mode = Self.mode(of: target)
        let migrated = Self.migratedCodexFeatures(String(decoding: bytes, as: UTF8.self))
        guard migrated.changed else { return "" }
        let backup = configuration.dataDirectory.appendingPathComponent("hook/backups").appendingPathComponent("codex-config.toml")
        if !FileManager.default.fileExists(atPath: backup.path) {
            // A backup that cannot be made is a reason not to rewrite the file.
            do { try BackendAccountFiles.writeAtomic(bytes, to: backup) } catch { return "" }
        }
        try writeSettings(Data(migrated.text.utf8), mode: mode, to: target)
        return "Renamed the deprecated codex_hooks flag to hooks in \(file.path), so Codex stops printing a deprecation line at every session start."
    }

    // MARK: first-run offer (hooks.ts `hookOfferAnswer` … `declineHookOffer`)

    /// hooks.ts `hookOfferAnswer`: absent, unreadable or unparseable all mean no answer on record.
    private func offerAnswer() -> String? {
        guard let bytes = try? BackendAccountFiles.boundedRead(offerFile, maximum: 4096), let parsed = try? NativeRPCValue.parseJSON(bytes) else { return nil }
        let answer = parsed["answer"].string
        return answer == "accepted" || answer == "declined" ? answer : nil
    }
    /// hooks.ts `recordHookOfferAnswer`.
    private func recordOfferAnswer(_ answer: String) throws {
        let clock = ISO8601DateFormatter(); clock.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let body = NativeRPCValue.object([.init("answer", .string(answer)), .init("at", .string(clock.string(from: Date())))])
        try BackendAccountFiles.writeAtomic(try body.encodedJSON(pretty: true) + Data("\n".utf8), to: offerFile)
    }
    /// hooks.ts `readHookOffer`: shown only with no answer on record, on a genuinely fresh machine (none of ours —
    /// or another copy's — anywhere), and with something to install into.
    public func offer() -> NativeRPCValue {
        let answered = offerAnswer(), statuses = allStatus()
        let eligible = statuses.filter { $0.fileExists && $0.state == "none" }
        let fresh = statuses.allSatisfy { $0.state != "complete" && $0.state != "stale" && $0.state != "partial" }
        let followUps = eligible.compactMap { Self.requirement($0.id) }
        return .object([.init("show", .bool(answered == nil && fresh && !eligible.isEmpty)), .init("answered", answered.map(NativeRPCValue.string) ?? .null),
            .init("eligible", .array(eligible.map(\.wireValue))), .init("followUps", .array(followUps.map(NativeRPCValue.string)))])
    }
    /// Accept is hooks.ts `acceptHookOffer` and answers its per-provider results (`{ok, message, status}`); decline is
    /// the `hooks:offer-decline` handler and answers the offer. Consent is recorded even when one install fails.
    public func answerOffer(accept: Bool, context: NativeRPCContext) throws -> NativeRPCValue {
        try authorize(context)
        guard accept else {
            // An unwritable marker means the strip returns next launch with a working button.
            try? recordOfferAnswer("declined")
            return offer()
        }
        // Not `offer().eligible`: a file that went unparseable since the strip was drawn gets install's refusal, in the results.
        let results = allStatus().filter { $0.fileExists && ($0.state == "none" || $0.state == "error") }.map { row -> NativeRPCValue in
            do {
                let result = try performInstall(row.id)
                return .object([.init("ok", .bool(true)), .init("message", .string(result.message)), .init("status", result.status.wireValue)])
            } catch {
                return .object([.init("ok", .bool(false)), .init("message", .string(error.localizedDescription)), .init("status", status(row.id).wireValue)])
            }
        }
        try? recordOfferAnswer("accepted")
        return .array(results)
    }
}
