import Foundation

// Machines → Servers, as pure logic: the readers of `machines/servers/types.ts`,
// the sentences of `words.ts`, `group-notes.ts`, `key-routes.ts`, the Add-server
// rules, the host panel's rules, the folder picker's rules, and the Advanced
// panel's lines — in their own words, for the native Servers screens.

// MARK: - What a look at a server found (`servers:look` → ServerView)

/// One fact about a server: known (with its value), known not to be there, or not
/// findable (with why). Absent is "not asked yet".
public enum ServerFact: Equatable, Sendable {
    case yes(CodingAIJSON)
    case no
    case cannot(String)

    /// `asFact`: nil for anything that is not a fact, or a `yes` whose value does not read.
    static func parse(_ value: CodingAIJSON, read: (CodingAIJSON) -> CodingAIJSON?) -> ServerFact? {
        guard value.isObject else { return nil }
        switch value["known"].string {
        case "yes": return read(value["value"]).map { .yes($0) }
        case "no": return ServerFact.no
        case "cannot": return .cannot(value["why"].string ?? "")
        default: return nil
        }
    }

    public var value: CodingAIJSON? {
        if case .yes(let value) = self { return value }
        return nil
    }
}

public struct ServerFacts: Equatable, Sendable {
    public var facts: [String: ServerFact] = [:]

    public subscript(key: String) -> ServerFact? { facts[key] }

    /// `asFacts`, with the old spellings each fact once had.
    public static func parse(_ value: CodingAIJSON) -> ServerFacts {
        guard value.isObject else { return ServerFacts() }
        let text: (CodingAIJSON) -> CodingAIJSON? = { $0.text.map(CodingAIJSON.string) }
        let number: (CodingAIJSON) -> CodingAIJSON? = { $0.number.map(CodingAIJSON.number) }
        let amount: (CodingAIJSON) -> CodingAIJSON? = { raw in
            guard raw.isObject, let total = raw["totalKb"].number, total > 0 else { return nil }
            if let used = raw["usedKb"].number { return .object(["usedKb": .number(used), "totalKb": .number(total)]) }
            guard let free = raw["freeKb"].number else { return nil }
            return .object(["usedKb": .number(max(0, total - free)), "totalKb": .number(total)])
        }
        let count: (CodingAIJSON) -> CodingAIJSON? = { raw in
            if let list = raw.array { return .number(Double(list.count)) }
            return raw.number.map(CodingAIJSON.number)
        }
        let agents: (CodingAIJSON) -> CodingAIJSON? = { raw in raw.array == nil ? nil : raw }
        var out: [String: ServerFact] = [:]
        func put(_ key: String, _ sources: [String], _ read: (CodingAIJSON) -> CodingAIJSON?) {
            for source in sources {
                if let fact = ServerFact.parse(value[source], read: read) {
                    out[key] = fact
                    return
                }
            }
        }
        put("os", ["os"], text)
        put("kernel", ["kernel"], text)
        put("arch", ["arch"], text)
        put("hostname", ["hostname"], text)
        put("user", ["user"], text)
        put("init", ["init"], text)
        put("packageManager", ["packageManager", "packages"], text)
        put("webServer", ["webServer", "web"], text)
        put("cpus", ["cpus"], number)
        put("disk", ["disk"], amount)
        put("memory", ["memory"], amount)
        put("load", ["load1", "load"], number)
        put("uptimeSeconds", ["uptimeSeconds", "uptime"], number)
        put("listeners", ["listeners"], count)
        put("agents", ["agents"], agents)
        return ServerFacts(facts: out)
    }

    func known(_ key: String) -> CodingAIJSON? { facts[key]?.value }
}

public struct ServerCardInfo: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable { case site, app, database, other }
    public var id: String
    public var kind: Kind
    public var name: String
    public var detail: String
    public var running: Bool?
    public var url: String?

    public init(id: String, kind: Kind, name: String, detail: String = "", running: Bool? = nil, url: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.detail = detail
        self.running = running
        self.url = url
    }
}

public struct ServerActionPreview: Equatable, Sendable, Identifiable {
    public enum Klass: String, Sendable { case safe, reversible, kept }
    public var actionId: String
    public var klass: Klass
    public var label: String
    public var target: String
    public var sentence: String
    public var wayBack: String?
    public var keeps: String?
    public var id: String { actionId }

    /// `asPreview`.
    public static func parse(_ value: CodingAIJSON) -> ServerActionPreview? {
        guard value.isObject, let actionId = value["actionId"].text, let label = value["label"].text,
              let klass = value["klass"].string.flatMap(Klass.init(rawValue:)) else { return nil }
        return ServerActionPreview(actionId: actionId, klass: klass, label: label, target: value["target"].string ?? "",
                                   sentence: value["sentence"].string ?? "", wayBack: value["wayBack"].text, keeps: value["keeps"].text)
    }
}

public struct ServerAbsentAction: Equatable, Sendable {
    public var actionId: String
    public var because: String
}

public struct ServerView: Equatable, Sendable {
    public var cards: [ServerCardInfo]
    public var facts: ServerFacts
    public var offered: [String: [String]]
    public var absent: [String: [ServerAbsentAction]]
    public var how: [String]
    public var cannot: [(what: String, why: String)]
    public var measuredAt: Double

    public static func == (lhs: ServerView, rhs: ServerView) -> Bool {
        lhs.cards == rhs.cards && lhs.facts == rhs.facts && lhs.offered == rhs.offered && lhs.absent == rhs.absent
            && lhs.how == rhs.how && lhs.measuredAt == rhs.measuredAt
            && lhs.cannot.map(\.what) == rhs.cannot.map(\.what) && lhs.cannot.map(\.why) == rhs.cannot.map(\.why)
    }

    /// `asView`.
    public static func parse(_ value: CodingAIJSON) -> ServerView? {
        guard value.isObject else { return nil }
        let cards: [ServerCardInfo] = (value["cards"].array ?? []).compactMap { raw in
            guard raw.isObject, let id = raw["id"].text, let name = raw["name"].text else { return nil }
            return ServerCardInfo(id: id, kind: raw["kind"].string.flatMap(ServerCardInfo.Kind.init(rawValue:)) ?? .other,
                                  name: name, detail: raw["detail"].string ?? "", running: raw["running"].bool, url: raw["url"].text)
        }
        var offered: [String: [String]] = [:]
        for (key, raw) in value["offered"].object ?? [:] { offered[key] = (raw.array ?? []).compactMap(\.text) }
        var absent: [String: [ServerAbsentAction]] = [:]
        for (key, raw) in value["absent"].object ?? [:] {
            absent[key] = (raw.array ?? []).compactMap { entry in
                guard entry.isObject, let actionId = entry["actionId"].text, let because = entry["because"].text else { return nil }
                return ServerAbsentAction(actionId: actionId, because: because)
            }
        }
        let cannot: [(what: String, why: String)] = (value["cannot"].array ?? []).compactMap { entry in
            guard entry.isObject, let why = entry["why"].text else { return nil }
            return (entry["what"].string ?? "", why)
        }
        return ServerView(cards: cards, facts: ServerFacts.parse(value["facts"]), offered: offered, absent: absent,
                          how: (value["how"].array ?? []).compactMap(\.text), cannot: cannot,
                          measuredAt: value["measuredAt"].number ?? 0)
    }
}

/// A grant letting the assistant act on one server for a while.
public struct ServerGrant: Equatable, Sendable {
    public var serverId: String
    public var expiresAt: Double
    public var grantedAt: Double

    /// `asGrant`.
    public static func parse(_ value: CodingAIJSON) -> ServerGrant? {
        guard value.isObject, let serverId = value["serverId"].text, let expiresAt = value["expiresAt"].number else { return nil }
        return ServerGrant(serverId: serverId, expiresAt: expiresAt, grantedAt: value["grantedAt"].number ?? 0)
    }
}

/// Where one server's page has got to (`ServerState`).
public struct ServerRoomState: Equatable, Sendable {
    public enum Link: String, Sendable { case connecting, ready, failed }
    public var id: String
    public var link: Link
    public var problem: String?
    public var identityChanged = false
    public var identity: (expected: String, offered: String)?
    public var view: ServerView?
    public var previews: [String: [ServerActionPreview]] = [:]
    public var grant: ServerGrant?

    public init(id: String, link: Link, problem: String? = nil) {
        self.id = id
        self.link = link
        self.problem = problem
    }

    public static func == (lhs: ServerRoomState, rhs: ServerRoomState) -> Bool {
        lhs.id == rhs.id && lhs.link == rhs.link && lhs.problem == rhs.problem && lhs.identityChanged == rhs.identityChanged
            && lhs.identity?.expected == rhs.identity?.expected && lhs.identity?.offered == rhs.identity?.offered
            && lhs.view == rhs.view && lhs.previews == rhs.previews && lhs.grant == rhs.grant
    }

    /// A refused look (`asRefusal`): its sentence, and whether the identity changed.
    public static func failed(_ id: String, refusal value: CodingAIJSON) -> ServerRoomState {
        var state = ServerRoomState(id: id, link: .failed,
                                    problem: value.isObject ? (value["sentence"].text ?? "That did not work, and this server did not say why.")
                                                            : "Nothing came back from that. Nothing may have happened.")
        let identity = value["identity"]
        if identity.isObject { state.identity = (identity["expected"].string ?? "", identity["offered"].string ?? "") }
        state.identityChanged = value["kind"].string == "identity-changed" || state.identity != nil
        return state
    }
}

/// An action's result (`asOutcome`).
public struct ServerActionOutcome: Equatable, Sendable {
    public var done: String
    public var wayBack: (actionId: String, label: String)?

    public init(done: String, wayBack: (actionId: String, label: String)?) {
        self.done = done
        self.wayBack = wayBack
    }

    public static func == (lhs: ServerActionOutcome, rhs: ServerActionOutcome) -> Bool {
        lhs.done == rhs.done && lhs.wayBack?.actionId == rhs.wayBack?.actionId && lhs.wayBack?.label == rhs.wayBack?.label
    }

    public static func parse(_ value: CodingAIJSON) -> ServerActionOutcome {
        guard value.isObject else { return ServerActionOutcome(done: "Done.", wayBack: nil) }
        let back = value["wayBack"]
        var wayBack: (String, String)?
        if back.isObject, let id = back["actionId"].text, let label = back["label"].text { wayBack = (id, label) }
        return ServerActionOutcome(done: value["done"].text ?? "Done.", wayBack: wayBack)
    }
}

// MARK: - The sentences (`words.ts`)

public enum ServerWords {
    static let minute = 60.0, hour = 3600.0, day = 86_400.0

    public static func howLong(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        if seconds < minute { return "less than a minute" }
        if seconds < hour { let m = Int(seconds / minute); return m == 1 ? "1 minute" : "\(m) minutes" }
        if seconds < day { let h = Int(seconds / hour); return h == 1 ? "1 hour" : "\(h) hours" }
        let d = Int(seconds / day)
        return d == 1 ? "1 day" : "\(d) days"
    }

    /// `asOf`: how long ago, in the words a person uses (times in ms).
    public static func asOf(_ measuredAt: Double, now: Double) -> String {
        let seconds = ((now - measuredAt) / 1000).rounded(.down)
        if !seconds.isFinite || seconds < 45 { return "just now" }
        if seconds < hour { let m = Int((seconds / minute).rounded()); return m == 1 ? "1 minute ago" : "\(m) minutes ago" }
        if seconds < day { let h = Int(seconds / hour); return h == 1 ? "1 hour ago" : "\(h) hours ago" }
        let d = Int(seconds / day)
        return d == 1 ? "yesterday" : "\(d) days ago"
    }

    /// `nextAgeChange`: when `asOf` will next say something different (ms).
    public static func nextAgeChange(_ measuredAt: Double, now: Double) -> Double {
        let seconds = ((now - measuredAt) / 1000).rounded(.down)
        if !seconds.isFinite { return now + day * 1000 }
        if seconds < 45 { return measuredAt + 45_000 }
        if seconds < hour {
            let minutes = (seconds / minute).rounded()
            return measuredAt + ((minutes + 0.5) * minute).rounded() * 1000
        }
        if seconds < day { return measuredAt + ((seconds / hour).rounded(.down) + 1) * hour * 1000 }
        return measuredAt + ((seconds / day).rounded(.down) + 1) * day * 1000
    }

    public static func busyness(load: Double, cpus: Double) -> String {
        guard cpus > 0 else { return "" }
        let perCore = load / cpus
        if perCore < 0.7 { return "Light" }
        if perCore < 1 { return "Steady" }
        return "Busy"
    }

    public struct Reading: Equatable, Sendable, Identifiable {
        public var id: String
        public var label: String
        public var value: String
    }

    /// `readings`: Storage, Memory, Workload, On for — none of them inside a container.
    public static func readings(_ facts: ServerFacts?) -> [Reading] {
        guard let facts else { return [] }
        let inContainer = facts.known("init")?.string == "container-none"
        var out: [Reading] = []
        func share(_ amount: CodingAIJSON) -> Int {
            Int(((amount["usedKb"].number ?? 0) / (amount["totalKb"].number ?? 1) * 100).rounded())
        }
        if !inContainer, let disk = facts.known("disk") { out.append(Reading(id: "disk", label: "Storage", value: "\(share(disk))% full")) }
        if !inContainer, let memory = facts.known("memory") { out.append(Reading(id: "memory", label: "Memory", value: "\(share(memory))% in use")) }
        if !inContainer, let load = facts.known("load")?.number, let cpus = facts.known("cpus")?.number {
            let word = busyness(load: load, cpus: cpus)
            if !word.isEmpty { out.append(Reading(id: "load", label: "Workload", value: word)) }
        }
        if !inContainer, let uptime = facts.known("uptimeSeconds")?.number {
            let span = howLong(uptime)
            if !span.isEmpty { out.append(Reading(id: "uptime", label: "On for", value: span)) }
        }
        return out
    }

    public static func runningWord(_ running: Bool?) -> String {
        guard let running else { return "Can't tell" }
        return running ? "Running" : "Stopped"
    }

    /// `overallSentence`.
    public static func overall(_ cards: [ServerCardInfo]?) -> String {
        guard let cards else { return "" }
        if cards.isEmpty { return "There's nothing here we can check on." }
        let stopped = cards.filter { $0.running == false }
        if stopped.count == 1 { return "\(stopped[0].name) isn't running." }
        if stopped.count > 1 { return "\(stopped.count) things aren't running." }
        let unsure = cards.filter { $0.running == nil }
        if unsure.count == cards.count { return "We couldn't check anything on this server." }
        if !unsure.isEmpty { return "Everything we can check is running." }
        return "Everything's running."
    }

    public static func linkSentence(_ link: ServerRoomState.Link) -> String {
        link == .connecting ? "Connecting…" : ""
    }

    public static func groupHeading(_ kind: ServerCardInfo.Kind) -> String {
        switch kind {
        case .site: return "Websites"
        case .app: return "Apps"
        case .database: return "Databases"
        case .other: return "Other things running"
        }
    }

    public static let nothingFound = "We couldn't find anything this server is set up to keep running. You can still open a terminal on this server."
    public static let noDetail = "We could not tell what this is."

    /// `groupReasons`: reasons every card in a group shares, said once; the rest per card.
    public static func groupReasons(_ cards: [ServerCardInfo], absent: [String: [ServerAbsentAction]]) -> (shared: [String], own: [String: [ServerAbsentAction]]) {
        let per = cards.map { absent[$0.id] ?? [] }
        guard cards.count >= 2 else {
            return ([], Dictionary(uniqueKeysWithValues: zip(cards.map(\.id), per)))
        }
        var shared: [String] = []
        for row in per[0] where !shared.contains(row.because) && per.allSatisfy({ $0.contains { $0.because == row.because } }) {
            shared.append(row.because)
        }
        var own: [String: [ServerAbsentAction]] = [:]
        for (index, card) in cards.enumerated() { own[card.id] = per[index].filter { !shared.contains($0.because) } }
        return (shared, own)
    }

    public static let logsFirst = 200, logsMore = 400, logsMost = 2000

    /// `asLogLines`.
    public static func logLines(_ value: CodingAIJSON) -> [String] {
        guard value["ok"].isTrue else { return [] }
        return (value["lines"].array ?? []).map { $0.string ?? "" }
    }
}

// MARK: - The servers list extras

extension CodingAIServer {
    /// The fields the Servers screens read beyond the Coding AI list.
    public struct Extra: Equatable, Sendable {
        public var credential: String?
        public var fingerprint: String?
        public var drivesWindows: Bool

        public init(credential: String?, fingerprint: String?, drivesWindows: Bool) {
            self.credential = credential
            self.fingerprint = fingerprint
            self.drivesWindows = drivesWindows
        }
    }

    /// `asServer`'s other fields, by id.
    public static func parseExtras(_ value: CodingAIJSON) -> [String: Extra] {
        var out: [String: Extra] = [:]
        for raw in value.array ?? [] {
            guard raw.isObject, let id = raw["id"].text else { continue }
            let credential = raw["credential"].string.flatMap { ["password", "key", "none"].contains($0) ? $0 : nil }
            out[id] = Extra(credential: credential, fingerprint: raw["hostKey"]["fingerprint"].text,
                            drivesWindows: raw["drivesWindows"].isTrue)
        }
        return out
    }
}

// MARK: - Advanced (`ServerAdvanced.tsx`)

public enum ServerAdvancedText {
    public static let grantMs = 60.0 * 60 * 1000

    public static func credentialLine(_ credential: String?) -> String {
        switch credential {
        case nil: return "This build did not say."
        case "none": return "Nothing is kept. You will be asked again next time."
        case "key": return "A key, sealed by this computer and never shown on any screen."
        default: return "A password, sealed by this computer and never shown on any screen."
        }
    }

    public static func identityLine(_ fingerprint: String?) -> String { fingerprint ?? "It has not told us one yet." }

    /// `FactLine`'s value.
    public static func factLine(_ fact: ServerFact?, say: (CodingAIJSON) -> String, none: String) -> String {
        switch fact {
        case nil: return "We have not asked yet."
        case .cannot(let why)?: return why.isEmpty ? "This sign-in could not find out." : why
        case .no?: return none
        case .yes(let value)?: return say(value)
        }
    }

    public static func listenersLine(_ value: CodingAIJSON) -> String {
        let n = Int(value.number ?? 0)
        return n == 1 ? "1 thing" : "\(n) things"
    }

    public static func allowedFor(_ grant: ServerGrant, now: Double) -> String {
        "Allowed for another \(ServerWords.howLong(max(0, ((grant.expiresAt - now) / 1000).rounded(.down))))"
    }
}

// MARK: - Add a server (`AddServer.tsx`, `key-routes.ts`)

public enum AddServerRules {
    public enum Failure: String, Sendable, CaseIterable {
        case needsPassphrase = "needs-passphrase", badPassphrase = "bad-passphrase", keyUnreadable = "key-unreadable"
        case signInRefused = "sign-in-refused", noSuchAddress = "no-such-address", noAnswer = "no-answer"
        case notAServer = "not-a-server", saidNothing = "said-nothing", nothingInCommon = "nothing-in-common", unknown
    }

    public static func wantsPassphrase(_ reason: Failure?, passphrase: String) -> Bool {
        reason == .needsPassphrase || reason == .badPassphrase || !passphrase.isEmpty
    }

    /// `readPort`: empty is the usual port; else a whole number 1…65535.
    public static func readPort(_ raw: String) -> (ok: Bool, port: Int?, sentence: String?) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return (true, nil, nil) }
        guard value.allSatisfy(\.isASCII), value.allSatisfy(\.isNumber), let port = Int(value) else {
            return (false, nil, "That is a number, like 2222. Leave it empty for the usual one.")
        }
        guard (1...65535).contains(port) else {
            return (false, nil, "It has to be between 1 and 65535. Leave it empty for the usual one.")
        }
        return (true, port, nil)
    }

    public static let portHelp = "Leave it empty unless you were given a number — nearly every server uses the usual one, and empty means that."

    /// The draft `servers:add` takes.
    public static func draft(address: String, port: Int?, username: String, method: String, password: String, key: String,
                             passphrase: String, locked: Bool, name: String, remember: Bool) -> CodingAIJSON {
        var draft: [String: CodingAIJSON] = [
            "address": .string(address.trimmingCharacters(in: .whitespacesAndNewlines)),
            "username": .string(username.trimmingCharacters(in: .whitespacesAndNewlines)),
            "method": .string(method),
            "remember": .bool(remember),
        ]
        if let port { draft["port"] = .number(Double(port)) }
        if method == "password" { draft["password"] = .string(password) } else { draft["key"] = .string(key) }
        if locked && !passphrase.isEmpty { draft["passphrase"] = .string(passphrase) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { draft["name"] = .string(trimmed) }
        return .object(draft)
    }

    /// `asAddResult`.
    public static func result(_ value: CodingAIJSON) -> (ok: Bool, id: String?, reason: Failure, message: String) {
        guard value.isObject else { return (false, nil, .unknown, "Nothing came back from that attempt. Try it again.") }
        if value["ok"].isTrue, let id = value["id"].text { return (true, id, .unknown, "") }
        let stated = value["kind"].string ?? value["reason"].string
        let reason = stated.flatMap(Failure.init(rawValue:)) ?? .unknown
        let message = value["sentence"].text ?? value["message"].text ?? "That did not work, and the server did not say why."
        return (false, nil, reason, message)
    }

    public struct KeyOffer: Equatable, Sendable, Identifiable {
        public var path: String
        public var name: String
        public var what: String
        public var locked: Bool?
        public var id: String { path }

        /// `asKeyOffer`.
        public static func parse(_ value: CodingAIJSON) -> KeyOffer? {
            guard value.isObject, let path = value["path"].text, let name = value["name"].text else { return nil }
            return KeyOffer(path: path, name: name, what: value["what"].string ?? "A key", locked: value["locked"].bool)
        }

        /// `keyRowSays`.
        public var says: String { locked == true ? "\(what) · needs a password to open" : what }
    }

    public static func keyOffers(_ value: CodingAIJSON) -> [KeyOffer] { (value.array ?? []).compactMap(KeyOffer.parse) }

    /// `asKeyText`.
    public static func keyText(_ value: CodingAIJSON) -> (ok: Bool, key: String?, sentence: String) {
        let fallback = "That file could not be read. Choose it again."
        guard value.isObject else { return (false, nil, fallback) }
        if value["ok"].isTrue, let key = value["key"].string { return (true, key, "") }
        return (false, nil, value["sentence"].text ?? fallback)
    }

    /// `keyRoutes`.
    public static func keyRoutes(hasChooser: Bool, found: Int, chosen: Bool, pasting: Bool) -> (list: Bool, panel: Bool, paste: Bool, offerPaste: Bool) {
        guard hasChooser else { return (false, false, true, false) }
        let paste = pasting || (found == 0 && !chosen)
        return (found > 0, true, paste, !paste)
    }

    /// `pasteBoxText`.
    public static func pasteBoxText(fromFile: Bool, typed: String) -> String { fromFile ? "" : typed }
}

// MARK: - The host on a server (`ServerHost.tsx`)

public struct ServerHostState: Equatable, Sendable {
    public enum Step: String, Sendable { case idle, checking, uploading, installing, service, pairing, done, removing, failed }
    public var serverId: String
    public var step: Step
    public var line: String
    public var detail: String
    public var done: [String]
    public var code: String?
    public var weInstalled: Bool

    /// `asHostState`.
    public static func parse(_ value: CodingAIJSON) -> ServerHostState? {
        guard value.isObject, let serverId = value["serverId"].text else { return nil }
        return ServerHostState(serverId: serverId, step: value["step"].string.flatMap(Step.init(rawValue:)) ?? .idle,
                               line: value["line"].string ?? "", detail: value["detail"].string ?? "",
                               done: (value["done"].array ?? []).compactMap(\.text), code: value["code"].text,
                               weInstalled: value["weInstalled"].isTrue)
    }

    public var working: Bool { step != .idle && step != .done && step != .failed }
}

public struct ServerHostOffer: Equatable, Sendable {
    public enum Running: String, Sendable { case yes, no, unknown }
    public var command: String
    public var version: String
    public var running: Running
    public var status: String
    public var address: String
    public var canInstall: Bool
    public var why: String?
    public var line: String
    public var reach: String?
    public var consequence: String
    public var removesKeepData: String
    public var removesWithData: String
    public var canLink: Bool
    public var linkedAs: String?
    public var linkedButNotConnected: Bool
    public var mine: String
    public var state: ServerHostState

    /// `asHostOffer` (inside `{ ok, offer }`).
    public static func parse(_ value: CodingAIJSON) -> ServerHostOffer? {
        let host = value["host"], room = value["room"]
        guard value.isObject, host.isObject, room.isObject, let state = ServerHostState.parse(value["state"]) else { return nil }
        let running = host["running"].string
        return ServerHostOffer(
            command: host["command"].string ?? "", version: host["version"].string ?? "",
            running: running == "yes" ? .yes : running == "no" ? .no : .unknown,
            status: host["status"].string ?? "", address: host["address"].string ?? "",
            canInstall: value["canInstall"].isTrue, why: value["why"].text, line: value["line"].string ?? "",
            reach: value["reach"].text, consequence: value["consequence"].string ?? "",
            removesKeepData: value["removes"]["keepData"].string ?? "", removesWithData: value["removes"]["withData"].string ?? "",
            canLink: value["canLink"].isTrue, linkedAs: value["linkedAs"].text,
            linkedButNotConnected: value["linkedButNotConnected"].isTrue, mine: value["mine"].string ?? "", state: state)
    }

    public var here: Bool { !command.isEmpty }
}

public enum ServerHostRules {
    public struct Controls: Equatable, Sendable {
        public var here: Bool
        public var install: Bool
        public var update: String?
        public var link: Bool
        public var pair: Bool
        public var remove: Bool
        public var stop: Bool
        public var why: String?
        public var reach: String?
        public var linkedAs: String?
        public var away: Bool
    }

    /// `hostControls`.
    public static func controls(_ offer: ServerHostOffer, busy: Bool) -> Controls {
        let here = offer.here
        return Controls(
            here: here,
            install: !busy && !here && offer.canInstall,
            update: busy ? nil : updateAvailable(command: offer.command, version: offer.version, mine: offer.mine),
            link: !busy && here && offer.canLink && (offer.linkedAs == nil || offer.linkedButNotConnected),
            pair: !busy && here,
            remove: !busy && here,
            stop: busy,
            why: !busy && !here ? offer.why : nil,
            reach: !busy && here ? offer.reach : nil,
            linkedAs: !busy && here ? offer.linkedAs : nil,
            away: !busy && here && offer.linkedAs != nil && offer.linkedButNotConnected)
    }

    static func semver(_ text: String) -> [Int]? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") { trimmed.removeFirst() }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var out: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(part) else { return nil }
            out.append(n)
        }
        while out.count < 3 { out.append(0) }
        return out
    }

    /// `hostUpdateAvailable`: this app's version when the server's is older.
    public static func updateAvailable(command: String, version: String, mine: String) -> String? {
        guard !command.isEmpty, let there = semver(version), let here = semver(mine) else { return nil }
        for index in 0..<3 where there[index] != here[index] { return there[index] < here[index] ? mine : nil }
        return nil
    }

    public static func linkedLine(_ name: String) -> String {
        "This computer is linked to it, as \(name) in Machines. Sessions, folders and the terminal work there the way they do for any other machine."
    }

    public static func awayLine(_ name: String) -> String {
        "This computer has a row for it — \(name) in Machines — and nothing is reaching it: that host says nothing is connected to it. This app has just dialled it again. If this sentence is still here the next time you open this page, Link this computer mints a fresh pairing and replaces the row."
    }

    public static func noAddressLine(_ running: ServerHostOffer.Running) -> String {
        switch running {
        case .no: return "There is no address for a phone while the host on this server is not running. Start it, and this panel will show the address to paste."
        case .unknown: return "This server did not say whether its host is running, so there is no address to show. What it says about itself, below, is the whole of what it answered."
        case .yes: return "This server has no address to hand out: its host is running and is not on a relay, so there is no slot for a phone to find it in. What it says about itself, below, says why — and a host older than this feature prints no address at all, which upgrading it fixes."
        }
    }

    public static let addressHow = "Paste it into the app on your phone or another computer: Add a server, then sign in with a username and password or key this server already accepts."
    public static let addressNotASecret = "This address is not a secret. It holds a public key and this server’s public name at a relay, and it grants nothing on its own — the login is the gate."
    public static let serverCopilot = "A device you sign in as your own gets Hoot on this server too — its chat, files, routines and settings — driven from here, because the server has no screen of its own. A device you add as a guest never gets it."
    public static let pairingHelp = "Type it into the app on your phone, or into Machines on another computer. It is good for about a minute. Then check the fingerprint in the terminal below against the one that device shows, and answer y — that check is the whole point of a fingerprint, so nothing here answers it for you."

    /// A refusal's sentence (`sentence`, else `message`).
    public static func sentence(_ value: CodingAIJSON) -> String {
        guard value.isObject else { return "That did not work." }
        return value["sentence"].text ?? value["message"].text ?? "That did not work."
    }
}

/// The host reached over the relay (`ServerHostRelayControl.tsx`).
public struct ServerHostControl: Equatable, Sendable {
    public var running: Bool
    public var version: String
    public var uptimeSeconds: Double
    public var managed: String
    public var note: String?

    /// `asHostControlWire`.
    public static func parse(_ value: CodingAIJSON) -> ServerHostControl? {
        guard value.isObject else { return nil }
        let managed = value["managed"].string.flatMap { ["systemd", "direct"].contains($0) ? $0 : nil } ?? "unknown"
        return ServerHostControl(running: value["running"].isTrue, version: value["version"].string ?? "",
                                 uptimeSeconds: value["uptimeSeconds"].number ?? 0, managed: managed, note: value["note"].text)
    }

    public static func spell(_ seconds: Double) -> String {
        let days = Int(seconds / 86400)
        if days >= 1 { return days == 1 ? "1 day" : "\(days) days" }
        let hours = Int(seconds / 3600)
        if hours >= 1 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        let minutes = max(1, Int(seconds / 60))
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    /// `managedDetail`.
    public var detail: String {
        var parts: [String] = []
        if uptimeSeconds > 0 { parts.append("up for \(Self.spell(uptimeSeconds))") }
        if managed == "systemd" { parts.append("it comes back on its own after a restart") }
        if managed == "direct" { parts.append("it is re-launched after a restart") }
        return parts.isEmpty ? "Reached over the relay." : parts.joined(separator: " · ")
    }

    public var say: String { version.isEmpty ? "Running." : "Running \(version)." }
}

/// A machine's GitHub, reached over the relay (`ServerConnectGitHub.tsx`).
public struct ServerGitHub: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case signingIn, connected, notConfigured, ready }
    public var connected: Bool
    public var login: String?
    public var name: String?
    public var source: String?
    public var appConfigured: Bool
    public var installUrl: String?
    public var userCode: String?
    public var verificationUri: String?
    public var failure: String?

    /// `asGitHubHostWire`.
    public static func parse(_ value: CodingAIJSON) -> ServerGitHub? {
        guard value.isObject else { return nil }
        let pending = value["pending"]
        let code = pending.isObject ? pending["userCode"].text : nil
        return ServerGitHub(connected: value["connected"].isTrue, login: value["login"].text, name: value["name"].text,
                            source: value["source"].text, appConfigured: value["appConfigured"].isTrue,
                            installUrl: value["installUrl"].text, userCode: code,
                            verificationUri: code == nil ? nil : (pending["verificationUri"].string ?? ""),
                            failure: value["failure"].text)
    }

    /// `Content`'s choice.
    public var phase: Phase {
        if userCode != nil { return .signingIn }
        if connected { return .connected }
        if !appConfigured { return .notConfigured }
        return .ready
    }

    /// The line under @login: the name, else where it came from.
    public var subtitle: String? {
        if let name, !name.isEmpty { return name }
        return source
    }

    public static let notConfigured = "This machine has no GitHub App set up, so there is nothing to connect to yet."
}

// MARK: - The folder picker (`ServerFolderPicker.tsx`)

public enum ServerFolders {
    public static let defaultFolder = "Wherever this sign-in lands"

    /// `folderLine`.
    public static func line(path: String?, fallback: String?) -> (shown: String, note: String) {
        let isDefault = "Its default folder. Every session on it starts here."
        guard let path else {
            return fallback.map { ($0, isDefault) } ?? (defaultFolder, "No folder chosen, so it lands wherever the sign-in does.")
        }
        if path == fallback { return (path, isDefault) }
        return (path, fallback.map { "Chosen for this session. Its default is \($0)." } ?? "Chosen for this session.")
    }

    /// `inNameOrder`: dot-folders last, then case-insensitive by name.
    public static func inNameOrder(_ names: [String]) -> [String] {
        names.enumerated().sorted { lhs, rhs in
            let a = lhs.element.hasPrefix("."), b = rhs.element.hasPrefix(".")
            if a != b { return !a }
            let order = lhs.element.compare(rhs.element, options: [.caseInsensitive, .diacriticInsensitive])
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    public static func childOf(_ folder: String, _ name: String) -> String {
        folder.hasSuffix("/") ? "\(folder)\(name)" : "\(folder)/\(name)"
    }

    public struct Folder: Equatable, Sendable {
        public var path: String
        public var folders: [String]
        public var files: Int
    }

    /// `asFolder` (after `succeeded`): the folders in it, and how many files are not shown.
    public static func parse(_ value: CodingAIJSON) -> Folder? {
        guard value.isObject, let path = value["path"].text else { return nil }
        var folders: [String] = []
        var files = 0
        for entry in value["entries"].array ?? [] {
            guard entry.isObject, let name = entry["name"].text else { continue }
            let kind = entry["kind"].string
            if kind == "folder" || kind == "link" { folders.append(name) } else { files += 1 }
        }
        return Folder(path: path, folders: folders, files: files)
    }

    /// The stored default folder (`servers:start-in`).
    public static func storedFolder(_ value: CodingAIJSON) -> String? { value["path"].text }

    public static func filesNotShown(_ count: Int) -> String {
        "\(count == 1 ? "1 file here is not shown" : "\(count) files here are not shown") — a session starts in a folder."
    }
}
