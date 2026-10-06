import Foundation

// The New session dialog's rules, ported from the page so the native dialog
// decides exactly what the page dialog decides:
//   - `session-start.ts`: `resolveStart`, the remembered per-folder choices
//     (`parseStartMemory`, `rememberStart`, `projectDefaultsFor`)
//   - `NewSessionDialog.tsx`: recent projects and the shortlist, sign-in lines,
//     `parseAddOutcome`
//   - `ProviderPicker.tsx`: `buildProviderRows`
//   - `ProfilePicker.tsx`: `normalizeProjectKey`, `isolationNotice`, `profileBadges`
//   - `shared/custom-agents.ts`: `splitArgs`, `describeArgs`, the added agents
// Tests: NewSessionTests.swift mirrors the vitest files.

// MARK: - What the page hands over

public struct NewSessionMachine: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var folders: [String]
    public init(id: String, name: String, folders: [String]) {
        self.id = id
        self.name = name
        self.folders = folders
    }
}

public struct NewSessionServer: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// `{type:'new-session', seq, projectPath, machineId, machines, hereName, servers, liveSessions, memory}`.
public struct NewSessionContext: Equatable, Sendable {
    public var seq: Int
    public var projectPath: String?
    public var machineId: String?
    public var machines: [NewSessionMachine]
    public var hereName: String
    public var servers: [NewSessionServer]
    public var liveSessions: [String: Int]
    public var memory: String?

    public init(seq: Int = 1, projectPath: String? = nil, machineId: String? = nil, machines: [NewSessionMachine] = [],
                hereName: String = "This Mac", servers: [NewSessionServer] = [], liveSessions: [String: Int] = [:],
                memory: String? = nil) {
        self.seq = seq
        self.projectPath = projectPath
        self.machineId = machineId
        self.machines = machines
        self.hereName = hereName
        self.servers = servers
        self.liveSessions = liveSessions
        self.memory = memory
    }

    public static func parse(_ body: Any) -> NewSessionContext? {
        let value = CodingAIJSON(body)
        guard value["type"].string == "new-session" else { return nil }
        let machines = (value["machines"].array ?? []).compactMap { row -> NewSessionMachine? in
            guard let id = row["id"].text else { return nil }
            return NewSessionMachine(id: id, name: row["name"].string ?? id,
                                     folders: (row["folders"].array ?? []).compactMap(\.text))
        }
        let servers = (value["servers"].array ?? []).compactMap { row -> NewSessionServer? in
            guard let id = row["id"].text else { return nil }
            return NewSessionServer(id: id, name: row["name"].string ?? id)
        }
        var live: [String: Int] = [:]
        for (path, count) in value["liveSessions"].object ?? [:] {
            if let number = count.number { live[path] = Int(number) }
        }
        let here = value["hereName"].text ?? ""
        return NewSessionContext(seq: Int(value["seq"].number ?? 1),
                                 projectPath: value["projectPath"].text,
                                 machineId: value["machineId"].text,
                                 machines: machines,
                                 hereName: here.isEmpty ? "This Mac" : here,
                                 servers: servers,
                                 liveSessions: live,
                                 memory: value["memory"].string)
    }

    /// How many sessions run in a folder (the same folder spelt differently counts too).
    public func sessions(in path: String) -> Int {
        if let exact = liveSessions[path] { return exact }
        let wanted = NewSessionPaths.normalize(path)
        return liveSessions.filter { NewSessionPaths.normalize($0.key) == wanted }.reduce(0) { $0 + $1.value }
    }
}

// MARK: - Folders

public enum NewSessionPaths {
    /// `normalizeProjectKey`: `.`, `..` and doubled separators folded away.
    public static func normalize(_ path: String) -> String {
        if path.isEmpty { return "" }
        let separator: Character = path.contains("\\") && !path.contains("/") ? "\\" : "/"
        let rooted = path.first == "/" || path.first == "\\"
        var segments: [String] = []
        for part in path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init) {
            if part.isEmpty || part == "." { continue }
            if part == ".." {
                if let top = segments.last, top != ".." { segments.removeLast() } else if !rooted { segments.append("..") }
                continue
            }
            segments.append(part)
        }
        let joined = segments.joined(separator: String(separator))
        return rooted ? String(separator) + joined : joined
    }

    /// The last folder name (`folderName`).
    public static func folderName(_ path: String) -> String {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
    }
}

public struct NewSessionProject: Equatable, Sendable, Identifiable {
    public var path: String
    public var name: String
    public var lastOpenedAt: Double
    public var id: String { path }

    public init(path: String, name: String? = nil, lastOpenedAt: Double = 0) {
        self.path = path
        self.name = name ?? NewSessionPaths.folderName(path)
        self.lastOpenedAt = lastOpenedAt
    }
}

public enum NewSessionProjects {
    public static let maxRecent = 8

    /// `parseRecentProjects`: newest first, one row per path.
    public static func parse(_ raw: CodingAIJSON) -> [NewSessionProject] {
        var seen = Set<String>()
        var projects: [NewSessionProject] = []
        for entry in raw.array ?? [] {
            guard let path = entry["path"].string, !path.isEmpty, !seen.contains(path) else { continue }
            seen.insert(path)
            projects.append(NewSessionProject(path: path, lastOpenedAt: entry["lastOpenedAt"].number ?? 0))
        }
        return projects.enumerated().sorted { a, b in
            a.element.lastOpenedAt != b.element.lastOpenedAt ? a.element.lastOpenedAt > b.element.lastOpenedAt : a.offset < b.offset
        }.map(\.element)
    }

    /// `withProject`: a folder just browsed to goes to the top.
    public static func with(_ projects: [NewSessionProject], _ path: String, now: Double = Date().timeIntervalSince1970 * 1000) -> [NewSessionProject] {
        [NewSessionProject(path: path, lastOpenedAt: now)] + projects.filter { $0.path != path }
    }

    public static func match(_ projects: [NewSessionProject], _ query: String) -> [NewSessionProject] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        if needle.isEmpty { return projects }
        return projects.filter { $0.name.lowercased().contains(needle) || $0.path.lowercased().contains(needle) }
    }

    /// `projectShortlist`: the filter appears only past eight folders.
    public static func shortlist(_ projects: [NewSessionProject], filter: String, max: Int = maxRecent)
        -> (filtering: Bool, shown: [NewSessionProject], hidden: Int) {
        let filtering = projects.count > max
        let matched = filtering ? match(projects, filter) : projects
        return (filtering, Array(matched.prefix(max)), Swift.max(0, matched.count - max))
    }
}

// MARK: - Agents

public struct NewSessionCustomAgent: Equatable, Sendable {
    public var id: String
    public var label: String
    public var description: String
    public var command: String
    public var resumeArgs: [String]

    public static let prefix = "custom:"
    public static func isCustom(_ id: String?) -> Bool {
        guard let id else { return false }
        return id.hasPrefix(prefix) && id.count > prefix.count
    }

    /// `parseCustomAgents`: one row per id; a row without a name or command is dropped.
    public static func parse(_ raw: CodingAIJSON) -> [NewSessionCustomAgent] {
        var seen = Set<String>()
        var out: [NewSessionCustomAgent] = []
        for item in raw.array ?? [] {
            guard let id = item["id"].string, isCustom(id), !seen.contains(id) else { continue }
            let label = (item["label"].string ?? "").trimmingCharacters(in: .whitespaces)
            let command = (item["command"].string ?? "").trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, !command.isEmpty else { continue }
            seen.insert(id)
            out.append(NewSessionCustomAgent(
                id: id, label: label,
                description: (item["description"].string ?? "").trimmingCharacters(in: .whitespaces),
                command: command,
                resumeArgs: (item["resumeArgs"].array ?? []).compactMap(\.string)))
        }
        return out
    }
}

/// One card in the Agent list (`ProviderRow`).
public struct NewSessionProviderRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var description: String
    public var install: String?
    public var command: String?
    public var canResume: Bool
    public var available: Bool
    /// Why it cannot start, when it cannot.
    public var reason: String?
    public var isCustom: Bool { NewSessionCustomAgent.isCustom(id) }
    /// The line under the name: the reason, else the description.
    public var hint: String { reason ?? description }
}

public enum NewSessionProviders {
    public static let customLoginsNote = "You added this agent, so nothing here has measured how it stores a login or whether two of them can be kept apart. It runs under whatever login this machine already has."

    public static func isProviderId(_ id: String?) -> Bool {
        CodingAICatalog.isProvider(id) || NewSessionCustomAgent.isCustom(id)
    }

    /// `installedProviders`: nil (fail open) when the detector said nothing at all.
    public static func installed(_ detected: CodingAIJSON) -> [String]? {
        guard let entries = detected.object, !entries.isEmpty else { return nil }
        return entries.filter { id, ok in
            let truthy: Bool
            switch ok {
            case .bool(let flag): truthy = flag
            case .null: truthy = false
            default: truthy = ok.number.map { $0 != 0 } ?? (ok.string.map { !$0.isEmpty } ?? true)
            }
            return truthy && isProviderId(id)
        }.map(\.key)
    }

    /// `buildProviderRows`: the catalogue, then the agents added here, each with whether it can start.
    public static func rows(detected: CodingAIJSON, added: [NewSessionCustomAgent], brand: String = "Terminal Deck") -> [NewSessionProviderRow] {
        let installed = self.installed(detected)
        var rows = CodingAICatalog.all.map { agent in
            NewSessionProviderRow(id: agent.id, label: agent.label, description: agent.description,
                                  install: agent.install, command: agent.bin, canResume: agent.canResume,
                                  available: true, reason: nil)
        }
        rows += added.map { agent in
            NewSessionProviderRow(id: agent.id, label: agent.label,
                                  description: agent.description.isEmpty ? "Runs `\(agent.command)` in the project folder." : agent.description,
                                  install: nil, command: agent.command, canResume: !agent.resumeArgs.isEmpty,
                                  available: true, reason: nil)
        }
        for index in rows.indices {
            let id = rows[index].id
            let available = id == "shell" || installed == nil || installed!.contains(id)
            rows[index].available = available
            rows[index].reason = available ? nil : "\(brand) could not start `\(rows[index].command ?? id)` on this machine."
        }
        return rows
    }

    /// `isolationNotice`: why the Login choice does not apply to this agent, or nil when it does.
    public static func isolationNotice(_ provider: String?) -> String? {
        guard let provider else { return nil }
        if NewSessionCustomAgent.isCustom(provider) { return customLoginsNote }
        guard let agent = CodingAICatalog.agent(provider) else { return nil }
        return agent.canHaveAccounts ? nil : agent.loginsNote
    }
}

// MARK: - Remembered choices (`session-start.defaults.v1`)

public struct NewSessionDefaults: Equatable, Sendable {
    public var provider: String?
    public var profileId: String?
    public var resume: Bool?
    public init(provider: String? = nil, profileId: String? = nil, resume: Bool? = nil) {
        self.provider = provider
        self.profileId = profileId
        self.resume = resume
    }
}

/// The remembered choices, in the order they were stored (the oldest go first when trimmed).
public struct NewSessionMemory: Equatable, Sendable {
    public var entries: [(path: String, defaults: NewSessionDefaults)]
    public static let maxProjects = 100

    public init(entries: [(path: String, defaults: NewSessionDefaults)] = []) {
        self.entries = entries
    }

    public static func == (a: NewSessionMemory, b: NewSessionMemory) -> Bool {
        a.entries.count == b.entries.count && zip(a.entries, b.entries).allSatisfy { $0.path == $1.path && $0.defaults == $1.defaults }
    }

    /// `parseStartMemory`: unreadable is empty; an unknown agent is dropped from its entry.
    public static func parse(_ text: String?) -> NewSessionMemory {
        guard let text, let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return NewSessionMemory() }
        // Key order is the stored order; JSONSerialization does not keep it, so read it from the text.
        let ordered = object.keys.sorted { position(of: $0, in: text) < position(of: $1, in: text) }
        var entries: [(String, NewSessionDefaults)] = []
        for path in ordered where !path.isEmpty {
            guard let raw = object[path] as? [String: Any] else { continue }
            var entry = NewSessionDefaults()
            if let provider = raw["provider"] as? String, NewSessionProviders.isProviderId(provider) { entry.provider = provider }
            if let profile = raw["profileId"] as? String, !profile.isEmpty { entry.profileId = profile }
            if let resume = raw["resume"] as? Bool { entry.resume = resume }
            entries.append((path, entry))
        }
        return NewSessionMemory(entries: entries)
    }

    /// Where a key sits in the stored text — as `JSON.stringify` writes it (slashes
    /// unescaped), or escaped, whichever the text holds.
    private static func position(of key: String, in text: String) -> Int {
        for options: JSONSerialization.WritingOptions in [[.fragmentsAllowed, .withoutEscapingSlashes], [.fragmentsAllowed]] {
            guard let data = try? JSONSerialization.data(withJSONObject: [key], options: options),
                  var quoted = String(data: data, encoding: .utf8) else { continue }
            quoted.removeFirst()
            quoted.removeLast()
            if let range = text.range(of: quoted + ":") ?? text.range(of: quoted) {
                return text.distance(from: text.startIndex, to: range.lowerBound)
            }
        }
        return Int.max
    }

    /// `projectDefaultsFor`: this folder's, the same folder spelt differently, or none.
    public func defaults(for path: String) -> NewSessionDefaults {
        if path.isEmpty { return NewSessionDefaults() }
        if let exact = entries.first(where: { $0.path == path }) { return exact.defaults }
        let wanted = NewSessionPaths.normalize(path)
        if wanted.isEmpty { return NewSessionDefaults() }
        return entries.first(where: { NewSessionPaths.normalize($0.path) == wanted })?.defaults ?? NewSessionDefaults()
    }

    /// `rememberStart`: this folder's choice goes last; at most 100 folders kept.
    public func remembering(_ request: NewSessionRequest) -> NewSessionMemory {
        let key = NewSessionPaths.normalize(request.cwd)
        if key.isEmpty { return self }
        let kept = entries.filter { NewSessionPaths.normalize($0.path) != key }
        let trimmed = Array(kept.suffix(Self.maxProjects - 1))
        return NewSessionMemory(entries: trimmed + [(key, NewSessionDefaults(provider: request.provider, profileId: request.profileId, resume: request.resume))])
    }

    /// The stored text, in order (`JSON.stringify`).
    public var json: String {
        func quote(_ s: String) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
            let text = String(decoding: data, as: UTF8.self)
            return String(text.dropFirst().dropLast())
        }
        let body = entries.map { path, d -> String in
            var fields: [String] = []
            if let provider = d.provider { fields.append("\"provider\":\(quote(provider))") }
            fields.append("\"profileId\":\(d.profileId.map(quote) ?? "null")")
            if let resume = d.resume { fields.append("\"resume\":\(resume)") }
            return "\(quote(path)):{\(fields.joined(separator: ","))}"
        }
        return "{\(body.joined(separator: ","))}"
    }
}

// MARK: - Deciding the session (`resolveStart`)

public struct NewSessionStartProvider: Equatable, Sendable {
    public var id: String
    public var label: String
    public var available: Bool
    public var canResume: Bool
    public var supportsProfiles: Bool

    /// `toStartProviders`.
    public static func from(_ rows: [NewSessionProviderRow]) -> [NewSessionStartProvider] {
        rows.map { NewSessionStartProvider(id: $0.id, label: $0.label, available: $0.available, canResume: $0.canResume,
                                           supportsProfiles: NewSessionProviders.isolationNotice($0.id) == nil) }
    }
}

public struct NewSessionStartProfile: Equatable, Sendable {
    public var id: String
    public var name: String
    public var system: Bool
    public init(id: String, name: String, system: Bool = false) {
        self.id = id
        self.name = name
        self.system = system
    }
}

/// `SpawnRequest`, as the page's `createSession` takes it.
public struct NewSessionRequest: Equatable, Sendable {
    public var cwd: String
    public var provider: String
    public var resume: Bool
    public var profileId: String?
    public var cols: Int
    public var rows: Int
    public var firstPrompt: String
    public var title: String?

    public var json: [String: Any] {
        ["cwd": cwd, "provider": provider, "resume": resume, "profileId": profileId as Any? ?? NSNull(),
         "cols": cols, "rows": rows, "firstPrompt": firstPrompt, "title": title as Any? ?? NSNull()]
    }
}

public struct NewSessionNotice: Equatable, Sendable, Identifiable {
    public var code: String
    public var message: String
    public var id: String { code }
}

public enum NewSessionResolution: Equatable, Sendable {
    case ok(NewSessionRequest, notices: [NewSessionNotice])
    case problem(code: String, message: String, notices: [NewSessionNotice])

    public var request: NewSessionRequest? {
        if case .ok(let request, _) = self { return request }
        return nil
    }

    public var notices: [NewSessionNotice] {
        switch self {
        case .ok(_, let notices), .problem(_, _, let notices): return notices
        }
    }

    public var problem: String? {
        if case .problem(_, let message, _) = self { return message }
        return nil
    }
}

public enum NewSessionStart {
    public static let cols = 100
    public static let rows = 30

    public static func resolve(providers: [NewSessionStartProvider], profiles: [NewSessionStartProfile],
                               memory: NewSessionMemory, defaultProvider: String?, defaultProfileId: String?,
                               projectPath: String?, provider wantedProvider: String?, profileId wantedProfile: String?,
                               resume wantedResume: Bool? = false) -> NewSessionResolution {
        var notices: [NewSessionNotice] = []
        let cwd = (projectPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if cwd.isEmpty {
            return .problem(code: "no-project", message: "Choose a project folder to run the session in.", notices: notices)
        }
        let remembered = memory.defaults(for: cwd)

        // chooseProvider: the first wanted one that is available; else the first available.
        var denied: NewSessionStartProvider?
        var chosen: NewSessionStartProvider?
        for id in [wantedProvider, remembered.provider, defaultProvider] {
            guard let id, !id.isEmpty, let provider = providers.first(where: { $0.id == id }) else { continue }
            if provider.available { chosen = provider; break }
            if denied == nil { denied = provider }
        }
        if chosen == nil { chosen = providers.first(where: \.available) }
        guard let provider = chosen else {
            return .problem(code: "no-provider", message: "No agent could be found on your PATH, so there is nothing to start.", notices: notices)
        }
        if let denied, denied.id != provider.id {
            notices.append(NewSessionNotice(code: "provider-substituted",
                                            message: "\(denied.label) is not installed — starting \(provider.label) instead."))
        }

        let wantsResume = wantedResume ?? remembered.resume ?? false
        let resume = wantsResume && provider.canResume
        if wantsResume && !resume {
            notices.append(NewSessionNotice(code: "resume-unsupported",
                                            message: "\(provider.label) has no resume command — starting a fresh conversation."))
        }

        var profileId: String?
        if provider.supportsProfiles {
            var missing: String?
            var picked: String?
            for id in [wantedProfile, remembered.profileId, defaultProfileId] {
                guard let id, !id.isEmpty else { continue }
                if profiles.contains(where: { $0.id == id }) { picked = id; break }
                if missing == nil { missing = id }
            }
            if picked == nil { picked = (profiles.first(where: \.system) ?? profiles.first)?.id }
            profileId = picked
            if let missing, missing != picked {
                notices.append(NewSessionNotice(code: "profile-missing", message: picked == nil
                    ? "That profile no longer exists, and no other login is available."
                    : "That profile no longer exists — using the default login instead."))
            }
        } else if !(wantedProfile ?? "").isEmpty || !(remembered.profileId ?? "").isEmpty {
            notices.append(NewSessionNotice(code: "profile-not-applicable",
                                            message: "\(provider.label) uses its own login, so no profile is applied."))
        }

        return .ok(NewSessionRequest(cwd: cwd, provider: provider.id, resume: resume, profileId: profileId,
                                     cols: cols, rows: rows, firstPrompt: "", title: nil), notices: notices)
    }
}

// MARK: - Login line

public enum NewSessionLogin {
    /// `parseSignIn`: nil for anything that is not one of the four states.
    public static func signIn(_ raw: CodingAIJSON) -> CodingAISignIn? {
        guard let state = raw["state"].string.flatMap(CodingAISignIn.State.init(rawValue:)) else { return nil }
        return CodingAISignIn(state: state, account: raw["account"].text, plan: raw["plan"].text)
    }

    /// `loginLine`.
    public static func line(_ report: CodingAISignIn?) -> String? {
        guard let report else { return nil }
        switch report.state {
        case .signedIn:
            if let account = report.account { return report.plan.map { "\(account) · \($0)" } ?? account }
            return report.plan ?? "Signed in"
        case .signedOut: return "Not signed in"
        case .unknown: return "Sign-in state unknown"
        case .unsupported: return nil
        }
    }

    /// `loginHint`: the line, without repeating an address the pop-up already shows.
    public static func hint(_ report: CodingAISignIn?, optionLabel: String?) -> String? {
        guard let line = line(report) else { return nil }
        let shown = report?.state == .signedIn && report?.account != nil && optionLabel == report?.account
        if !shown { return line }
        return report?.plan.map { "Signed in · \($0)" } ?? "Signed in"
    }

    /// `loginOptionLabel`: the address only on the selected row (the one the probe ran for).
    public static func optionLabel(_ account: CodingAIAccount, selectedId: String?, report: CodingAISignIn?) -> String {
        CodingAIAccountLabels.profileLoginLabel(account, account.id == selectedId ? report : nil)
    }

    /// `isDefaultLogin` (`profileBadges` includes "Default").
    public static func isDefault(_ account: CodingAIAccount?, defaultId: String?) -> Bool {
        guard let account else { return false }
        return account.id == defaultId || (defaultId == nil && account.system)
    }
}

// MARK: - Add a CLI

public struct NewSessionAgentDraft: Equatable, Sendable {
    public var label = ""
    public var description = ""
    public var command = ""
    public var args = ""
    public var resumeArgs = ""
    public init() {}

    public var json: [String: Any] {
        ["label": label, "description": description, "command": command, "args": args, "resumeArgs": resumeArgs]
    }
}

public enum NewSessionAddAgent {
    public static let maxArgs = 24
    public static let maxLabel = 40
    public static let maxDescription = 120
    public static let fields = ["label", "description", "command", "args", "resumeArgs"]
    public static let refused = ["command": "That agent could not be added. Check the command and try again."]

    public enum Outcome: Equatable, Sendable {
        case added(String)
        case problems([String: String])
    }

    /// `parseAddOutcome`.
    public static func outcome(_ raw: CodingAIJSON) -> Outcome {
        guard raw.isObject else { return .problems(refused) }
        guard raw["ok"].bool == true else {
            guard raw["problems"].isObject else { return .problems(refused) }
            var problems: [String: String] = [:]
            for field in fields {
                if let text = raw["problems"][field].string, !text.isEmpty { problems[field] = text }
            }
            return .problems(problems.isEmpty ? refused : problems)
        }
        guard let id = raw["agent"]["id"].string, NewSessionCustomAgent.isCustom(id) else { return .problems(refused) }
        return .added(id)
    }

    /// `splitArgs`: whitespace separates; a quoted run stays in one piece; `""` is an empty argument.
    public static func splitArgs(_ raw: String) -> [String] {
        var args: [String] = []
        var current = ""
        var quote: Character?
        var started = false
        for char in raw {
            if let open = quote {
                if char == open { quote = nil } else { current.append(char) }
                continue
            }
            if char == "\"" || char == "'" {
                quote = char
                started = true
                continue
            }
            if char.isWhitespace {
                if started || !current.isEmpty { args.append(current) }
                current = ""
                started = false
                continue
            }
            current.append(char)
        }
        if started || !current.isEmpty { args.append(current) }
        return args
    }

    /// `describeArgs`.
    public static func describeArgs(_ args: [String]) -> String {
        if args.isEmpty { return "no arguments" }
        return args.map { arg in
            guard arg.contains(" ") || arg.isEmpty else { return arg }
            let data = (try? JSONSerialization.data(withJSONObject: [arg], options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
            return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
        }.joined(separator: " ")
    }

    /// The hints under Arguments and the resume arguments.
    public static func argsHint(_ raw: String) -> String {
        let args = splitArgs(raw)
        return args.isEmpty ? "Optional. A quoted argument stays in one piece." : "Sends: \(describeArgs(args))"
    }

    public static func resumeHint(_ raw: String) -> String {
        let args = splitArgs(raw)
        return args.isEmpty
            ? "Optional, and empty is the safe answer — leave it and this agent simply does not offer resume."
            : "Continues with: \(describeArgs(args))"
    }

    public static func note(brand: String = "Terminal Deck") -> String {
        "\(brand) checks the command exists on this machine when you add it, and then runs it in a terminal in the project folder. It has not measured how this agent stores a login or where it writes a transcript, so accounts, hooks and token tracking stay off for it. Up to \(maxArgs) arguments."
    }
}
