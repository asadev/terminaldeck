import Foundation
import TerminalDeckNativeCore
import TerminalDeckBackend

/// Owner, 14 Nov: the New session page always offers the model for an AI that has models, set to the model that will
/// really be used (his last one, else that AI's own default, named), and names the effort that will really be used.
///
/// Why it was missing on his Macs: the page's lists come from `NativePhoneStart.choices`, whose models are the live
/// catalogue (`hoot:ready:read` → `BackendHootModelSource.liveCatalogue`). With "Your own Claude Code install" in effect
/// that catalogue has NO Claude list (`fetchClaude` answers `.system`: Terminal Deck never borrows Claude Code's own
/// token), so every row came back with `models: []` and the page hid the Model chip (`showsModel`).
///
/// Here, for the page only (no message to a phone, the host or a socket changes), each AI row gets, in this order:
/// the live list; else the list a running chat of that AI offers (Claude Code's own choices from its handshake, the
/// same list that chat's box shows); else the last list seen on this Mac. And the default model and effort: the CLI's
/// own settings (`BackendHootReadyDefaults.cliDefaults`), else the model a running chat of that AI reports, else the
/// last one seen here. With none of those lists, Claude Code's own aliases (`untilTheRealListIsKnown`).
@MainActor
enum NativeLandingModels {
    static let memoryKey = "landing.models.v1"
    typealias Invoke = @MainActor (String, [NativeRPCValue]) async throws -> NativeRPCValue
    /// An AI's own default model and effort (nil: it does not say).
    typealias CLIDefault = @MainActor (String) -> (model: String?, effort: String?)

    static let cliDefault: CLIDefault = { provider in
        guard let ai = HootChatProvider(rawValue: provider) else { return (nil, nil) }
        let real = BackendHootReadyDefaults.cliDefaults(provider: ai, configDir: nil)
        return (usable(real.model), usable(real.effort))
    }

    /// UNTIL THE REAL LIST IS KNOWN. Written 14 Nov 2026 (LANDING-FIX-2), completed 15 Nov (review item 1: "when I click
    /// on Fable 5, it's not giving me all of models"). A Mac where no list was ever seen (his own Claude Code sign-in gives
    /// the app no live list: the session host's `profiles:claude-models` answers "system" whenever this Mac's own login is
    /// the account in effect, see the seat note 2026-11-15-new-session-review) still offers EVERY model Claude Code itself
    /// offers. These are the installed CLI's own model aliases, read from Claude Code 2.1.322 itself (its alias table:
    /// sonnet, opus, haiku, fable, sonnet[1m], opus[1m], fable[1m]; "best" and "opusplan" are not models of their own);
    /// each means the newest model of that line, as `claude --model <alias>` takes it. Claude Code's own per-account extras
    /// (`additionalModelOptionsCache` in ~/.claude.json, the list its own /model shows) are added by `claudeExtras`.
    /// Used only while the live list, a running chat's list and the last list seen on this Mac are all empty, never
    /// remembered, and replaced by the real list the moment one is seen. The ONE place in the code that names models.
    static let untilTheRealListIsKnown: [String: [(String, String)]] = [
        "claude": [("fable", "Fable"), ("fable[1m]", "Fable 1M"), ("opus", "Opus"), ("opus[1m]", "Opus 1M"),
                   ("sonnet", "Sonnet"), ("sonnet[1m]", "Sonnet 1M"), ("haiku", "Haiku")]
    ]

    /// Claude Code's own extra model choices for the account it is signed in with (its `additionalModelOptionsCache`,
    /// rows {value, label, description}), named as Claude Code's own /model names them ("Fable 5.2" from the description's
    /// first part, else the label). Read-only, bounded; nothing else in that file is read.
    typealias Extras = @MainActor (String) -> [(String, String)]
    static let claudeExtras: Extras = { provider in
        guard provider == "claude" else { return [] }
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size <= 32 * 1_048_576,
              let data = try? Data(contentsOf: file), let rows = (try? NativeRPCValue.parseJSON(data))?["additionalModelOptionsCache"].elements else { return [] }
        return extras(rows)
    }
    /// The rows of Claude Code's `additionalModelOptionsCache`, as (id, name).
    static func extras(_ rows: [NativeRPCValue]) -> [(String, String)] {
        rows.prefix(40).compactMap { row in
            guard let id = row["value"].string, usable(id) != nil, id.utf8.count <= 120 else { return nil }
            let said = row["description"].string?.components(separatedBy: " \u{00B7} ").first?.trimmingCharacters(in: .whitespaces)
            let named = [said, row["label"].string].compactMap { $0 }.first { !$0.isEmpty && $0.count <= 40 } ?? Self.name(id)
            return (id, id.hasSuffix("[1m]") && !named.contains("1M") ? named + " 1M" : named)
        }
    }

    struct Kept: Codable, Equatable { var models: [[String]]; var model: String? }

    static func filled(_ value: NativeRPCValue, invoke: Invoke, defaults: UserDefaults, cliDefault: CLIDefault,
                       extras: Extras = { _ in [] }) async -> NativeRPCValue {
        guard var rows = value["providers"].elements else { return value }
        var memory = remembered(defaults)
        var running: [String: (models: [(String, String)], model: String?)]? = nil
        for index in rows.indices {
            let row = rows[index]
            guard let id = row["id"].string, id != "shell" else { continue }
            var models: [(String, String)] = (row["models"].elements ?? []).compactMap { model in
                model["id"].string.map { ($0, model["name"].string ?? $0) }
            }
            let cli = cliDefault(id)
            var model = cli.model
            if models.isEmpty || model == nil {
                if running == nil { running = await runningChats(invoke) }
                if let live = running?[id] {
                    if models.isEmpty { models = live.models }
                    if model == nil { model = live.model }
                }
            }
            if models.isEmpty { models = memory[id]?.models.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil } ?? [] }
            if model == nil { model = memory[id]?.model }
            // Only a real list (or a real default) is remembered: the built-in one below never replaces it.
            if !models.isEmpty || model != nil { memory[id] = Kept(models: models.map { [$0.0, $0.1] }, model: model) }
            if models.isEmpty { models = builtIn(id, default: model, extras: extras(id)) }
            var next = row.setting("models", .array(models.map { .object([.init("id", .string($0.0)), .init("name", .string($0.1))]) }))
            if let model { next = next.setting("defaultModel", .string(model)) }
            if let effort = cli.effort, (row["efforts"].elements ?? []).contains(.string(effort)) {
                next = next.setting("defaultEffort", .string(effort))
            }
            rows[index] = next
        }
        if let data = try? JSONEncoder().encode(memory) { defaults.set(data, forKey: memoryKey) }
        return await withAgentChoices(value.setting("providers", .array(rows)), invoke: invoke)
    }

    /// Every model Claude Code itself offers, for a Mac where no list is known (15 Nov, DESIGN-FIXES NS-2): its aliases
    /// in their order, each replaced IN PLACE by the account's own extra of the same line and window ("Fable 5.2 1M" for
    /// fable[1m]); the account's other extras after them. One row per line and window: the alias of the default's own
    /// line is that default (the page puts it first by its real name, "Fable 5.2"), and the default line's 1M alias is
    /// named after it ("Fable 5.2 1M", never a bare "Fable 1M").
    static func builtIn(_ provider: String, default model: String?, extras: [(String, String)]) -> [(String, String)] {
        let taken = model.map(key)
        var rows: [(String, String)] = []
        var left = extras
        for alias in untilTheRealListIsKnown[provider] ?? [] where key(alias.0) != taken {
            if let own = left.firstIndex(where: { key($0.0) == key(alias.0) }) {
                rows.append(left.remove(at: own))
            } else if let model, line(alias.0) == line(model), key(alias.0).hasSuffix("[1m]") {
                rows.append((alias.0, name(model) + " 1M"))
            } else {
                rows.append(alias)
            }
        }
        for extra in left where key(extra.0) != taken && !rows.contains(where: { key($0.0) == key(extra.0) }) { rows.append(extra) }
        return rows
    }

    /// LANDING-FIX-4: each listed agent with the model and effort its saved record gives it (its own settings first,
    /// then its record's fields, as `BackendAgentSessionInput.make` launches it); none: it leaves them open.
    static func withAgentChoices(_ value: NativeRPCValue, invoke: Invoke) async -> NativeRPCValue {
        guard let agents = value["agents"].elements, !agents.isEmpty,
              let saved = (try? await invoke("tasks:state", []))?["agents"].elements else { return value }
        return value.setting("agents", .array(agents.map { row in
            guard let id = row["id"].string, let record = saved.first(where: { $0["id"].string == id }) else { return row }
            var next = row
            if let model = usable(record["agoptSettings"]["model"].string) ?? usable(record["model"].string) {
                next = next.setting("model", .string(model))
            }
            if let effort = usable(record["agoptSettings"]["effort"].string) ?? usable(record["effort"].string) {
                next = next.setting("effort", .string(effort))
            }
            // Its own "Before it changes files" (the CLI value), read the same way: the page shows it until he picks.
            // ("default" is a real mode here, Ask first, so not `usable`.)
            func given(_ raw: String?) -> String? { raw.flatMap { $0.isEmpty ? nil : $0 } }
            if let mode = given(record["agoptSettings"]["permissionMode"].string) ?? given(record["permissionMode"].string) {
                next = next.setting("permissionMode", .string(mode))
            }
            return next
        }))
    }

    /// One running chat per AI: the models its box offers and the model it runs (ids without the "claude:" part).
    private static func runningChats(_ invoke: Invoke) async -> [String: (models: [(String, String)], model: String?)] {
        guard let sessions = (try? await invoke("session:list", []))?.elements else { return [:] }
        var found: [String: (models: [(String, String)], model: String?)] = [:]
        for session in sessions {
            guard let id = session["id"].string, let provider = session["provider"].string, found[provider] == nil,
                  session["chat"].bool == true, session["exitCode"].isNullish,
                  let options = try? await invoke("session:chat:options", [.string(id)]) else { continue }
            let prefix = provider + ":"
            func bare(_ id: String) -> String { id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id }
            let models: [(String, String)] = (options["models"].elements ?? []).compactMap { row in
                guard let raw = row["id"].string, usable(bare(raw)) != nil else { return nil }
                return (bare(raw), row["name"].string ?? bare(raw))
            }
            found[provider] = (models, usable(options["model"].string.map(bare)))
        }
        return found
    }

    private static func remembered(_ defaults: UserDefaults) -> [String: Kept] {
        defaults.data(forKey: memoryKey).flatMap { try? JSONDecoder().decode([String: Kept].self, from: $0) } ?? [:]
    }

    /// A model's line: "claude-fable-5-2" → "fable", Claude Code's "opus[1m]" → "opus"; any other id is its own line.
    static func line(_ id: String) -> String {
        let base = id.replacingOccurrences(of: "[1m]", with: "").lowercased()
        let parts = base.split(separator: "-")
        if parts.count >= 3, parts[0] == "claude" { return String(parts[1]) }
        return base
    }

    /// A model's line and window together: "claude-fable-5-2" and "fable" are one row, "fable[1m]" another.
    static func key(_ id: String) -> String { line(id) + (id.lowercased().hasSuffix("[1m]") ? "[1m]" : "") }

    /// "default", "auto" and blanks name nothing.
    static func usable(_ id: String?) -> String? {
        guard let id, !["default", "auto", ""].contains(id.lowercased().replacingOccurrences(of: "[1m]", with: "")) else { return nil }
        return id
    }

    /// The model's own name when the list has none: "claude-opus-5-5" → "Opus 5.5", Claude Code's "opus" → "Opus",
    /// "opus[1m]" → "Opus 1M".
    static func name(_ id: String) -> String {
        let base = id.replacingOccurrences(of: "[1m]", with: ""), million = id.hasSuffix("[1m]") ? " 1M" : ""
        let parts = base.split(separator: "-")
        if parts.count >= 3, parts[0] == "claude" {
            let numbers = parts.dropFirst(2).prefix(2).filter { $0.count <= 2 && $0.allSatisfy(\.isNumber) }
            return parts[1].capitalized + (numbers.isEmpty ? "" : " " + numbers.joined(separator: ".")) + million
        }
        if !base.isEmpty, !base.contains("-"), !base.contains("/") { return base.capitalized + million }
        // 15 Nov small fixes item 2: never a raw id. Codex's "gpt-5.5" → "GPT-5.5", "gpt-5.5-codex" → "GPT-5.5 Codex";
        // Gemini's "gemini-2.5-pro" → "Gemini 2.5 Pro"; any other plain dashed id reads as words.
        guard !base.isEmpty, !base.contains("/"), !base.contains(":") else { return base + million }
        func word(_ part: Substring) -> String { part.first?.isNumber == true ? String(part) : part.prefix(1).uppercased() + part.dropFirst() }
        if parts.count >= 2, parts[0].lowercased() == "gpt" {
            return (["GPT-" + parts[1]] + parts.dropFirst(2).map(word)).joined(separator: " ") + million
        }
        return parts.map(word).joined(separator: " ") + million
    }
}

/// The "Before it changes files" modes an AI really has (15 Nov review item 3), shared by the New session page and Hoot's
/// box: each of the app's four modes whose value for this AI is one the AI accepts (`AGSCapabilities.permissionModes`).
/// Empty for an AI with no modes (a plain shell, an added CLI).
enum NewSessionPermissionModes {
    static func modes(provider: String) -> [HootPermissionMode] {
        guard let ai = HootChatProvider(rawValue: provider) else { return [] }
        let accepted = AGSCapabilities.permissionModes(provider: provider)
        return HootPermissionMode.allCases.filter { mode in
            BackendHOOTSIMPermissionMode(rawValue: mode.rawValue).map { accepted.contains($0.cliMode(provider: ai)) } ?? false
        }
    }
}
