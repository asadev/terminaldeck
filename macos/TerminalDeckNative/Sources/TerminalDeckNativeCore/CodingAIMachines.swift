import Foundation

// Where the agents run: this computer, the servers, and every linked device.
// Ports of the switch at the top of Settings → Coding AI (`ScopeSwitch`,
// `scopeAfterDevices`) and of `DeviceAccounts.tsx` / `machine-account.ts`.

// MARK: - The switch

public enum CodingAIScope: Hashable, Sendable {
    case thisMachine
    case servers
    case device(String)

    /// What the page would call it (`'this-machine'`, `'servers'`, `'device:<id>'`).
    public var wire: String {
        switch self {
        case .thisMachine: return "this-machine"
        case .servers: return "servers"
        case .device(let id): return "device:\(id)"
        }
    }

    public var deviceId: String? {
        if case .device(let id) = self { return id }
        return nil
    }

    /// A device forgotten while its scope was on screen falls back to this machine.
    public func after(devices: [CodingAIDevice]) -> CodingAIScope {
        guard let wanted = deviceId else { return self }
        return devices.contains { $0.id == wanted } ? self : .thisMachine
    }
}

public struct CodingAIScopeSeat: Equatable, Sendable, Identifiable {
    public var scope: CodingAIScope
    public var label: String
    public var id: String { scope.wire }
}

public enum CodingAIScopes {
    /// What to call the computer this app is running on: its hostname, else "This Mac".
    public static func hereName(_ here: String, platformPhrase: String = "This Mac") -> String {
        let named = here.trimmingCharacters(in: .whitespacesAndNewlines)
        return named.isEmpty ? platformPhrase : named
    }

    /// The seats, in order: this machine (by name), Servers, then each linked device.
    public static func seats(here: String, devices: [CodingAIDevice]) -> [CodingAIScopeSeat] {
        [CodingAIScopeSeat(scope: .thisMachine, label: hereName(here)),
         CodingAIScopeSeat(scope: .servers, label: "Servers")]
            + devices.map { CodingAIScopeSeat(scope: .device($0.id), label: $0.name) }
    }
}

// MARK: - Linked devices (`machines:list` / `machines:state`)

public struct CodingAIRemoteSession: Equatable, Sendable {
    public var id: String
    public var title: String
}

/// One linked machine that is online, with the sessions running on it.
public struct CodingAIDevice: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var online: Bool
    public var sessions: [CodingAIRemoteSession]
    /// What that machine's link says it can do (`host.control`, `github`, …).
    public var capabilities: [String] = []
}

public struct CodingAIMachinesView: Equatable, Sendable {
    /// Only the reachable ones — the switch offers a seat for a machine that is online.
    public var devices: [CodingAIDevice]
    public var here: String

    public static let empty = CodingAIMachinesView(devices: [], here: "")

    /// `asView` + `reachableMachines`.
    public static func parse(_ value: CodingAIJSON) -> CodingAIMachinesView {
        guard value.isObject else { return .empty }
        var links: [String: (state: String, sessions: [CodingAIRemoteSession], capabilities: [String])] = [:]
        for link in value["links"].array ?? [] {
            guard link.isObject, let id = link["id"].text else { continue }
            let sessions: [CodingAIRemoteSession] = (link["sessions"].array ?? []).compactMap { session in
                guard session.isObject, let sid = session["id"].text else { return nil }
                return CodingAIRemoteSession(id: sid, title: session["title"].string ?? "")
            }
            links[id] = (link["state"].string ?? "offline", sessions, (link["capabilities"].array ?? []).compactMap(\.text))
        }
        var devices: [CodingAIDevice] = []
        for machine in value["machines"].array ?? [] {
            guard machine.isObject, let id = machine["id"].text else { continue }
            guard let link = links[id], link.state == "online" else { continue }
            devices.append(CodingAIDevice(id: id, name: machine["name"].string ?? "", online: true, sessions: link.sessions,
                                          capabilities: link.capabilities))
        }
        return CodingAIMachinesView(devices: devices, here: value["here"].string ?? "")
    }
}

/// One login on another machine (`AccountWire`).
public struct CodingAIMachineAccount: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var provider: String?
    public var color: String?
    public var system: Bool
    /// Nil: that machine's build does not report sign-in at all.
    public var signIn: CodingAISignIn?

    /// What a machine that sent no sign-in is said to be.
    public static let notReported = CodingAISignIn(
        state: .unknown,
        detail: "That machine is running a build that does not say which login it is signed in as.")

    public var signInOrNotReported: CodingAISignIn { signIn ?? Self.notReported }

    /// `readAccount`: an id and a name, or not a row.
    public static func parse(_ value: CodingAIJSON) -> CodingAIMachineAccount? {
        guard value.isObject, let id = value["id"].text, let name = value["name"].text else { return nil }
        return CodingAIMachineAccount(
            id: id,
            name: name,
            provider: value["provider"].string,
            color: value["color"].text,
            system: value["system"].isTrue,
            signIn: value["signIn"].isObject ? CodingAIAccountsParse.signIn(value["signIn"]) : nil)
    }

    /// The row as the local ladder would name it — never the profile key.
    public var label: String {
        let account = CodingAIAccount(id: id, name: name, provider: provider, system: system)
        return CodingAIAccountLabels.profileLoginLabel(account, signIn)
    }

    /// The state line: the far machine's own sentence, or the state word when it sent none.
    public var stateLine: String {
        let state = signInOrNotReported
        return state.detail.isEmpty ? state.state.rawValue : state.detail
    }
}

public enum CodingAIMachineLogins {
    /// `machines:logins:read`: a list means answered (even empty); anything else means "could not ask".
    public static func parse(_ value: CodingAIJSON) -> (answered: Bool, accounts: [CodingAIMachineAccount]) {
        guard let list = value.array else { return (false, []) }
        return (true, list.compactMap(CodingAIMachineAccount.parse))
    }

    /// `machines:account:read` (the fallback through a session): `{current, accounts}`.
    public static func parseThroughSession(_ value: CodingAIJSON) -> (current: CodingAIMachineAccount?, accounts: [CodingAIMachineAccount])? {
        guard value.isObject else { return nil }
        let accounts = (value["accounts"].array ?? []).compactMap(CodingAIMachineAccount.parse)
        return (CodingAIMachineAccount.parse(value["current"]), accounts)
    }

    /// The far machine's answer to a sign-in or sign-out, always as a sentence.
    public static func outcome(_ value: CodingAIJSON) -> (ok: Bool, message: String, session: String?) {
        guard value.isObject else { return (false, "That machine did not answer.", nil) }
        return (value["ok"].isTrue, value["message"].string ?? "", value["session"].text)
    }

    /// What a device row offers: Sign in on the machine-scoped path; Sign out only
    /// for a signed-in login whose agent has a logout command.
    public static func offers(_ account: CodingAIMachineAccount, machineAnswered: Bool) -> (signIn: Bool, signOut: Bool, signOutNote: String?) {
        let state = account.signInOrNotReported.state
        let provider = account.provider
        let hasSignOut = provider.map(CodingAICatalog.hasSignOut) ?? false
        let signOut = machineAnswered && state == .signedIn && provider != nil && hasSignOut
        let note = (state == .signedIn && provider != nil && !hasSignOut) ? CodingAICatalog.signOutNote(provider ?? "") : nil
        return (machineAnswered, signOut, note)
    }

    // The sentences of the device pane, in its own words.
    public static func notConnected(_ name: String) -> String {
        "\(name) is not connected, and its logins are kept on it rather than here."
    }
    public static func asking(_ name: String) -> String { "Asking \(name)…" }
    public static func noWayToAsk(_ name: String) -> String {
        "\(name) is running a build that does not manage its logins from here, and it has no session open to read them through. Update it, or start one from the sidebar."
    }
    public static func nothingCameBack(_ name: String) -> String {
        "Nothing came back from \(name). That is either no logins over there, or a read that did not arrive."
    }
    public static func readThroughSession(_ name: String) -> String {
        "\(name) is running a build that does not manage its logins from here, so this is read through a session on it."
    }
    public static func didNotAnswer(_ name: String) -> String { "\(name) did not answer." }
    public static func heading(_ name: String) -> String { "On \(name)" }
}

// MARK: - Open sessions on this machine, by account (`session:list`)

public enum CodingAISessions {
    /// The titles of the open sessions running as each account.
    public static func titlesByAccount(_ value: CodingAIJSON) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for session in value.array ?? [] {
            guard session.isObject else { continue }
            guard session["exitCode"] == .null, let profile = session["profileId"].text else { continue }
            out[profile, default: []].append(session["title"].string ?? "")
        }
        return out
    }
}

// MARK: - Hoot on other machines (`useCopilotMachines.ts`, `remote-copilot-model.ts`)

/// One machine whose Hoot this computer could talk to: this one (id "") first,
/// then every linked machine with a name.
public struct CopilotMachineRow: Equatable, Sendable, Identifiable {
    public enum Reach: String, Sendable { case ready, refused, unreachable }
    public var id: String
    public var name: String
    public var reach: Reach
    /// The link has said hello for Hoot on the current connection.
    public var open: Bool

    public init(id: String, name: String, reach: Reach, open: Bool) {
        self.id = id
        self.name = name
        self.reach = reach
        self.open = open
    }

    /// `useCopilotMachines`: here, then each link whose machine has a name.
    public static func rows(_ view: CodingAIJSON) -> [CopilotMachineRow] {
        let here = CopilotMachineRow(id: "", name: CodingAIScopes.hereName(view["here"].string ?? ""), reach: .ready, open: true)
        var names: [String: String] = [:]
        for machine in view["machines"].array ?? [] {
            if let id = machine["id"].text { names[id] = machine["name"].string ?? "" }
        }
        var rest: [CopilotMachineRow] = []
        for link in view["links"].array ?? [] {
            guard let id = link["id"].text, let name = names[id], !name.isEmpty else { continue }
            let copilot = link["copilot"]
            let grant = copilot["grant"]
            // `asCopilotLink`: all five booleans, or there is no Hoot there for us.
            let valid = copilot.isObject && grant.isObject && grant["read"].bool != nil && grant["act"].bool != nil
                && grant["alter"].bool != nil && copilot["linked"].bool != nil && copilot["open"].bool != nil
            let reach: Reach = link["state"].string != "online" ? .unreachable : (valid && copilot["linked"].isTrue ? .ready : .refused)
            rest.append(CopilotMachineRow(id: id, name: name, reach: reach, open: valid && copilot["open"].isTrue))
        }
        return [here] + rest
    }
}

/// Hoot's conversation on another machine, as that machine reports it.
public struct RemoteCopilotBubble: Equatable, Sendable, Identifiable {
    public enum Role: String, Sendable { case you, agent }
    public var id: String
    public var role: Role
    public var text: String
    public var at: Double

    public init(id: String, role: Role, text: String, at: Double = 0) {
        self.id = id
        self.role = role
        self.text = text
        self.at = at
    }
}

public enum RemoteCopilotModel {
    public struct Report: Equatable, Sendable {
        public enum Desk: String, Sendable { case stopped, starting, running }
        public var desk: Desk
        public var run: String?
        public var profile: String?
    }

    /// `readChatFrame`: the messages, and whether they replace what is shown.
    public static func chat(_ value: CodingAIJSON) -> (messages: [RemoteCopilotBubble], reset: Bool)? {
        guard value.isObject, let raw = value["messages"].array else { return nil }
        let messages: [RemoteCopilotBubble] = raw.compactMap { row in
            guard row.isObject, let id = row["id"].text, let text = row["text"].string else { return nil }
            return RemoteCopilotBubble(id: id, role: row["role"].string == "agent" ? .agent : .you, text: text, at: row["at"].number ?? 0)
        }
        return (messages, value["reset"].isTrue)
    }

    /// `readStateReport`.
    public static func report(_ value: CodingAIJSON) -> Report? {
        guard value.isObject, let desk = value["desk"].string.flatMap(Report.Desk.init(rawValue:)) else { return nil }
        return Report(desk: desk, run: value["run"].text, profile: value["profile"].text)
    }

    /// `applyChat`: a reset replaces; otherwise each message updates in place or is added.
    public static func apply(_ current: [RemoteCopilotBubble], _ chat: (messages: [RemoteCopilotBubble], reset: Bool)) -> [RemoteCopilotBubble] {
        if chat.reset { return chat.messages }
        var next = current
        for message in chat.messages {
            if let at = next.firstIndex(where: { $0.id == message.id }) { next[at] = message } else { next.append(message) }
        }
        return next
    }

    /// `{ ok, message }` from attach / start / say.
    public static func outcome(_ value: CodingAIJSON) -> (ok: Bool, message: String) {
        guard value.isObject else { return (false, "") }
        return (value["ok"].isTrue, value["message"].string ?? "")
    }
}
