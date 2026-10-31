import Foundation
import os
import TerminalDeckNativeCore

/// Hoot's model pickers, LIVE only. Nothing here is a written list of model names.
/// - Claude Code: the account's own models from Anthropic's model list, fetched by Terminal Deck's
///   own account store with a login it keeps. Claude Code's own sign-in on this Mac is Claude Code's
///   and is never read: with that one in effect only the configured model is given.
///   Split into "featured" (the newest model of each line) and "more" (older ones); the CLI's
///   configured model is flagged as the default; Fast mode as Claude Code itself records it.
/// - Codex: the installed CLI's own model list (~/.codex/models_cache.json).
/// - Gemini: no model list is available from the CLI, so none is shown.
/// When the live read fails only the model the CLI currently uses is given (no error shown; logged).
public enum BackendHootModelSource {
    public struct Model: Sendable, Equatable {
        public let id: String, name: String, efforts: [String]
        public let contextWindow: Int?, maxContextWindow: Int?, oneMillion: Bool
        public var wire: NativeRPCValue {
            .object([.init("id", .string(id)), .init("name", .string(name)), .init("efforts", .array(efforts.map(NativeRPCValue.string))),
                     .init("contextWindow", contextWindow.map { .number(Double($0)) } ?? .null),
                     .init("maxContextWindow", maxContextWindow.map { .number(Double($0)) } ?? .null),
                     .init("oneMillion", .bool(oneMillion))])
        }
    }
    /// One Coding AI's picker: all models, the featured/more split, the default, Fast mode.
    public struct Picker: Sendable {
        public var models: [Model] = [], featured: [String] = [], more: [String] = []
        public var defaultModel: String?, current: String?
        public var fastAvailable = false, fastOn = false
        public var wire: NativeRPCValue {
            let real = models.filter { !["default", "auto", ""].contains($0.id.lowercased().replacingOccurrences(of: "[1m]", with: "")) }
            let ids = Set(real.map(\.id))
            return .object([.init("models", .array(real.map(\.wire))), .init("featured", .array(featured.filter(ids.contains).map(NativeRPCValue.string))),
                     .init("more", .array(more.filter(ids.contains).map(NativeRPCValue.string))),
                     .init("defaultModel", defaultModel.map(NativeRPCValue.string) ?? .null),
                     .init("current", current.map(NativeRPCValue.string) ?? .null),
                     .init("fastMode", fastAvailable ? .object([.init("available", .bool(true)), .init("on", .bool(fastOn))]) : .null)])
        }
    }

    /// Synchronous: only the local CLI caches (Codex). Claude needs liveCatalogue.
    public static func models(_ provider: HootChatProvider, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Model] {
        provider == .codex ? codex(home: home) : []
    }

    public static func liveCatalogue(home: URL = FileManager.default.homeDirectoryForCurrentUser, refresh: Bool = false) async -> NativeRPCValue {
        var fields: [NativeRPCValue.Field] = []
        for provider in HootReadyDefaults.providerOrder {
            let picker: Picker
            switch provider {
            case .claude: picker = await ClaudeLive.shared.picker(home: home, refresh: refresh)
            case .codex:
                var codexPicker = Picker(); codexPicker.models = codex(home: home); codexPicker.featured = codexPicker.models.map(\.id)
                codexPicker.current = codexConfiguredModel(home: home); codexPicker.defaultModel = codexPicker.current
                if codexPicker.models.isEmpty { log.error("Codex model list not found in its CLI cache") }
                picker = codexPicker
            case .gemini: picker = Picker() // no live list from the Gemini CLI: only the model in use is shown
            }
            fields.append(.init(provider.rawValue, picker.wire))
        }
        return .object(fields)
    }

    // MARK: Claude Code (live)

    static let log = Logger(subsystem: "dev.terminaldeck.app", category: "hoot-models")

    actor ClaudeLive {
        static let shared = ClaudeLive()
        private var cached: (at: Date, picker: Picker)?
        func picker(home: URL, refresh: Bool) async -> Picker {
            if !refresh, let cached, Date().timeIntervalSince(cached.at) < 300 { return cached.picker }
            var picker = Picker()
            let settings = BackendHootModelSource.claudeSettings(home: home)
            picker.current = settings.model
            picker.fastAvailable = settings.fastAvailable; picker.fastOn = settings.fastOn
            switch await BackendHootModelSource.fetchClaude() {
            case .failure(let reason):
                BackendHootModelSource.log.error("Claude Code model list not loaded: \(reason, privacy: .public)")
                return picker // not cached: the next open tries again
            case .success(let rows):
                picker.models = rows.map(\.model)
                // Featured: the newest active model of each line. More: the rest.
                var newest: [String: (id: String, created: String)] = [:]
                for row in rows where row.lifecycle == "active" {
                    let line = row.line ?? row.model.id
                    if newest[line].map({ row.created > $0.created }) ?? true { newest[line] = (row.model.id, row.created) }
                }
                let featuredIDs = Set(newest.values.map(\.id))
                picker.featured = rows.filter { featuredIDs.contains($0.model.id) }.map(\.model.id)
                picker.more = rows.filter { !featuredIDs.contains($0.model.id) }.map(\.model.id)
                // The CLI's configured model: an alias ("opus") means the featured model of that line.
                if let current = settings.model?.replacingOccurrences(of: "[1m]", with: "") {
                    picker.defaultModel = rows.first { $0.model.id == current }?.model.id ?? newest[current]?.id
                }
                cached = (Date(), picker)
                BackendHootModelSource.log.info("Claude Code model list loaded: \(rows.count) models")
                return picker
            }
        }
    }
    struct ClaudeRow { let model: Model; let line: String?; let created: String; let lifecycle: String }
    enum Fetch { case success([ClaudeRow]), failure(String) }

    static func fetchClaude() async -> Fetch {
        // ACCOUNTS-SPEC 3 (FORK-L1): the list is fetched beside Terminal Deck's own store, with a login kept there.
        // U23: when this Mac's own Claude Code sign-in is the account in effect (or a session host from before this
        // update cannot be asked), there is no list: that token belongs to Claude Code, and reading it out of the
        // Keychain to borrow it breaks (or starts Keychain prompts) whenever Claude Code or Anthropic tighten their rules.
        switch await BackendAccountModelList.ask() {
        case .body(let data)?:
            if case .success(let rows) = parseClaude(data) { return .success(rows) }
            return .failure("the account store's model list could not be read")
        case .failure(let reason)?: return .failure(reason)
        case .system?: return .failure("this Mac's own Claude Code sign-in is in effect; only Terminal Deck's own logins fetch the list")
        case nil: return .failure("no account store to fetch the list")
        }
    }
    /// Anthropic's models list as rows (the same reading whichever login fetched it).
    static func parseClaude(_ data: Data) -> Fetch {
        guard let rows = try? NativeRPCValue.parseJSON(data)["data"].elements else { return .failure("unreadable reply") }
        let parsed: [ClaudeRow] = rows.compactMap { row in
            guard let id = row["id"].string, BackendSharedText.matches(id, #"^claude-[a-z0-9.-]{1,80}$"#) else { return nil }
            let effortCaps = row["capabilities"]["effort"]
            let efforts = ["low", "medium", "high", "xhigh", "max"].filter { effortCaps[$0]["supported"].bool == true }
            let window = row["max_input_tokens"].number.map(Int.init)
            let model = Model(id: id, name: (row["display_name"].string ?? id).replacingOccurrences(of: "Claude ", with: "", options: [.anchored, .caseInsensitive]), efforts: efforts, contextWindow: window, maxContextWindow: nil,
                              oneMillion: (window ?? 0) >= 1_000_000)
            return ClaudeRow(model: model, line: row["line"].string, created: row["created_at"].string ?? "", lifecycle: row["lifecycle"].string ?? "active")
        }
        return parsed.isEmpty ? .failure("empty model list") : .success(parsed)
    }
    /// Claude Code's own records: its configured model, and Fast mode as it stores it.
    static func claudeSettings(home: URL) -> (model: String?, fastAvailable: Bool, fastOn: Bool) {
        let settings = (try? Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))).flatMap { try? NativeRPCValue.parseJSON($0) } ?? .null
        let state = (try? Data(contentsOf: home.appendingPathComponent(".claude.json"))).flatMap { $0.count <= 32 * 1_048_576 ? try? NativeRPCValue.parseJSON($0) : nil } ?? .null
        return (settings["model"].string, state["penguinModeOrgEnabled"].bool == true, settings["fastMode"].bool == true)
    }

    // MARK: Codex (its CLI's own list)

    static func codex(home: URL) -> [Model] {
        let file = home.appendingPathComponent(".codex/models_cache.json")
        guard let data = try? Data(contentsOf: file), data.count <= 8 * 1_048_576,
              let root = try? NativeRPCValue.parseJSON(data), let rows = root["models"].elements else { return [] }
        return rows.compactMap { row in
            guard let id = row["slug"].string, !id.isEmpty, id.utf8.count <= 120,
                  BackendSharedText.matches(id, #"^[A-Za-z0-9][A-Za-z0-9._:-]*$"#),
                  row["visibility"].string == nil || row["visibility"].string == "list" else { return nil }
            let efforts = (row["supported_reasoning_levels"].elements ?? []).compactMap { $0["effort"].string }
                .filter { AGSCapabilities.efforts(provider: "codex").contains($0) }
            let window = row["context_window"].number.map(Int.init), maxWindow = row["max_context_window"].number.map(Int.init)
            return Model(id: id, name: row["display_name"].string ?? id, efforts: efforts.isEmpty ? AGSCapabilities.efforts(provider: "codex") : efforts,
                         contextWindow: window, maxContextWindow: maxWindow.flatMap { m in window.map { m > $0 ? m : nil } ?? m }, oneMillion: false)
        }
    }
    static func codexConfiguredModel(home: URL) -> String? {
        guard let text = try? String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("model ") || line.hasPrefix("model=") {
            let value = line.split(separator: "=", maxSplits: 1).last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
            if let value, !value.isEmpty { return value }
        }
        return nil
    }

    /// The larger context Codex can use for this model, when it offers one.
    public static func codexMaxWindow(model: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Int? {
        guard let model else { return nil }
        return codex(home: home).first { $0.id == model }?.maxContextWindow
    }
}
