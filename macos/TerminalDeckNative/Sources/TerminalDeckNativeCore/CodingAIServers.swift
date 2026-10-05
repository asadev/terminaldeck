import Foundation

// The Servers seat of Settings → Coding AI: the stored servers, the coding
// logins on each one once it is opened, and setting an agent up on it.
// Ports of `ServerAccounts.tsx`, `ServerSetup.tsx` and the readers in
// `machines/servers/types.ts`.

// MARK: - The stored servers (`servers:list`)

public struct CodingAIServer: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var address: String
    public var port: Int?
    public var username: String

    /// `asServers`: an id and an address, or not a row.
    public static func parseList(_ value: CodingAIJSON) -> [CodingAIServer] {
        (value.array ?? []).compactMap { raw in
            guard raw.isObject, let id = raw["id"].text, let address = raw["address"].text else { return nil }
            var port: Int?
            if let number = raw["port"].number, number.rounded() == number, number >= 1, number <= 65535 { port = Int(number) }
            return CodingAIServer(id: id, name: raw["name"].text ?? address, address: address, port: port, username: raw["username"].string ?? "")
        }
    }

    /// `serverWhere`: `user at host[:port]`, the port only when it is not 22.
    public var whereLine: String {
        var host = address
        if let port, port != 22 {
            if address.contains(":") && !address.hasPrefix("[") { host = "[\(address)]" }
            host += ":\(port)"
        }
        return username.isEmpty ? host : "\(username) at \(host)"
    }
}

// MARK: - What opening one finds (`servers:look`)

public struct CodingAIAgentOnServer: Equatable, Sendable {
    public enum SignedIn: String, Equatable, Sendable { case yes, no, unknown }
    public var id: String
    public var path: String
    public var version: String
    public var signedIn: SignedIn
    public var account: String?

    /// `readAgents`: an id and a path, or not a row.
    public static func parseList(_ value: CodingAIJSON) -> [CodingAIAgentOnServer]? {
        guard let list = value.array else { return nil }
        return list.compactMap { entry in
            guard entry.isObject, let id = entry["id"].text, let path = entry["path"].text else { return nil }
            let signed = entry["signedIn"].string
            return CodingAIAgentOnServer(
                id: id, path: path, version: entry["version"].string ?? "",
                signedIn: signed == "yes" ? .yes : signed == "no" ? .no : .unknown,
                account: entry["account"].text)
        }
    }
}

/// Where one opened server row has got to.
public enum CodingAIServerLook: Equatable, Sendable {
    case looking
    /// The coding-agents fact: known (the list), or the sentence for why it could not be known.
    case agents([CodingAIAgentOnServer])
    case cannot(String)
    case notAsked
    case failed(String)

    /// The reply to `servers:look`: `{ ok: true, view }`, or a refusal with its sentence.
    public static func parse(_ value: CodingAIJSON, serverName: String) -> CodingAIServerLook {
        guard value.isObject else { return .failed("Nothing came back from that. Nothing may have happened.") }
        if !value["ok"].isTrue {
            return .failed(value["sentence"].text ?? "That did not work, and this server did not say why.")
        }
        let view = value["view"]
        guard view.isObject else { return .failed("\(serverName) answered with something this build cannot read.") }
        let fact = view["facts"]["agents"]
        guard fact.isObject else { return .notAsked }
        switch fact["known"].string {
        case "yes":
            guard let list = CodingAIAgentOnServer.parseList(fact["value"]) else { return .notAsked }
            return .agents(list)
        case "no":
            return .agents([])
        case "cannot":
            return .cannot(fact["why"].string ?? "")
        default:
            return .notAsked
        }
    }
}

public struct CodingAIServerAgentRow: Equatable, Sendable, Identifiable {
    public enum State: String, Equatable, Sendable {
        case signedIn = "signed-in"
        case signedOut = "signed-out"
        case unknown
    }
    public var id: String
    public var label: String
    public var version: String
    public var state: State
    public var line: String
}

public struct CodingAIServerAgentRun: Equatable, Sendable, Identifiable {
    public var kind: CodingAIAccountRun.Kind
    public var agents: [CodingAIServerAgentRow]
    public var id: String { kind.rawValue }
    public var title: String? { CodingAIAccountRun.title(kind) }
}

public enum CodingAIServerAgents {
    public static let ids = ["claude", "codex", "gemini"]

    /// `serverAgentRuns`: every agent this app knows, filed into the runs.
    public static func runs(_ found: [CodingAIAgentOnServer]) -> [CodingAIServerAgentRun] {
        let rows: [CodingAIServerAgentRow] = ids.map { id in
            let label = CodingAICatalog.label(id)
            guard let agent = found.first(where: { $0.id == id }) else {
                return CodingAIServerAgentRow(id: id, label: label, version: "", state: .signedOut, line: "Not installed")
            }
            let broken = agent.version.isEmpty
            switch agent.signedIn {
            case .yes:
                return CodingAIServerAgentRow(id: id, label: label, version: agent.version, state: .signedIn,
                                              line: agent.account.map { "Signed in as \($0)" } ?? "Signed in")
            case .no:
                return CodingAIServerAgentRow(id: id, label: label, version: agent.version, state: .signedOut,
                                              line: broken ? "Installed, and would not start" : "Not signed in")
            case .unknown:
                return CodingAIServerAgentRow(id: id, label: label, version: agent.version, state: .unknown,
                                              line: broken ? "Installed, and would not start" : "Installed. This server did not say whether it is signed in.")
            }
        }
        func runOf(_ row: CodingAIServerAgentRow) -> CodingAIAccountRun.Kind {
            switch row.state {
            case .signedIn: return .signedIn
            case .unknown: return .notAnswered
            case .signedOut: return .notSignedIn
            }
        }
        let order: [CodingAIAccountRun.Kind] = [.signedIn, .notSignedIn, .notAnswered]
        return order.compactMap { kind in
            let mine = rows.filter { runOf($0) == kind }
            return mine.isEmpty ? nil : CodingAIServerAgentRun(kind: kind, agents: mine)
        }
    }

    public static let intro = "Opening a server here connects to it and reads what it has. Setting an agent up, signing it in and signing it out all work from the row."

    public static func notAsked(_ name: String) -> String { "\(name) was not asked about coding agents." }
}

// MARK: - Setting an agent up (`servers:setup:*`)

public struct CodingAISetupState: Equatable, Sendable {
    public enum Step: String, Equatable, Sendable { case idle, installing, installed, signingIn = "signing-in", done, failed }
    public var serverId: String
    public var agentId: String
    public var step: Step
    public var line: String
    public var detail: String
    /// A route this app cannot watch to the end: the person says when it is done.
    public var byHand: Bool
    /// The one-time code a device sign-in is waiting for.
    public var code: String
    public var weInstalled: Bool
    public var version: String?

    /// `asSetupState`.
    public static func parse(_ value: CodingAIJSON) -> CodingAISetupState? {
        guard value.isObject, let serverId = value["serverId"].text,
              let agentId = value["agentId"].string, CodingAIServerAgents.ids.contains(agentId) else { return nil }
        return CodingAISetupState(
            serverId: serverId,
            agentId: agentId,
            step: value["step"].string.flatMap(Step.init(rawValue:)) ?? .idle,
            line: value["line"].string ?? "",
            detail: value["detail"].string ?? "",
            byHand: value["byHand"].isTrue,
            code: value["code"].string ?? "",
            weInstalled: value["weInstalled"].isTrue,
            version: value["version"].text)
    }
}

public struct CodingAISetupRow: Equatable, Sendable, Identifiable {
    public var agentId: String
    public var label: String
    public var installed: CodingAIAgentOnServer?
    public var canInstall: Bool
    public var why: String?
    public var consequence: String
    public var signOutConsequence: String
    public var whyNoSignOut: String?
    public var state: CodingAISetupState
    public var id: String { agentId }

    /// `asSetupOffer` (after `succeeded`): the rows, or nil for anything else.
    public static func parseOffer(_ value: CodingAIJSON) -> [CodingAISetupRow]? {
        guard value.isObject, value["ok"].isTrue, let list = value["rows"].array else { return nil }
        return list.compactMap { raw in
            guard raw.isObject, let state = CodingAISetupState.parse(raw["state"]),
                  let agentId = raw["agentId"].string, CodingAIServerAgents.ids.contains(agentId) else { return nil }
            let installed = CodingAIAgentOnServer.parseList(.array([raw["installed"]]))?.first
            return CodingAISetupRow(
                agentId: agentId,
                label: raw["label"].string ?? "",
                installed: installed,
                canInstall: raw["canInstall"].isTrue,
                why: raw["why"].text,
                consequence: raw["consequence"].string ?? "",
                signOutConsequence: raw["signOutConsequence"].string ?? "",
                whyNoSignOut: raw["whyNoSignOut"].text,
                state: state)
        }
    }

    /// `lineFor`: the flow's own line while something is happening, else the standing description.
    public func line(_ state: CodingAISetupState) -> String {
        if state.step != .idle && !state.line.isEmpty { return state.line }
        guard let agent = installed else { return "\(label) isn’t set up on this server yet." }
        if agent.version.isEmpty { return "\(label) is on this server but won’t start." }
        switch agent.signedIn {
        case .yes:
            if let account = agent.account { return "\(label) \(agent.version), signed in as \(account)." }
            return "\(label) \(agent.version), signed in."
        case .no:
            return "\(label) \(agent.version) — not signed in."
        case .unknown:
            return "\(label) \(agent.version) is here."
        }
    }

    /// The buttons a row offers while nothing else is running.
    public struct Offers: Equatable, Sendable {
        public var setUp = false
        public var signIn = false
        public var signOut = false
        public var installAgain = false
        public var remove = false
        public var why: String?
        public var whyNoSignOut: String?
    }

    public func offers(_ state: CodingAISetupState, idle: Bool, canSignOut: Bool) -> Offers {
        var offers = Offers()
        guard idle else { return offers }
        if let agent = installed {
            offers.signIn = !agent.version.isEmpty && agent.signedIn != .yes
            offers.signOut = agent.signedIn == .yes && canSignOut && whyNoSignOut == nil
            offers.installAgain = agent.version.isEmpty && canInstall
            offers.remove = state.weInstalled
            if agent.signedIn == .yes { offers.whyNoSignOut = whyNoSignOut }
        } else {
            offers.setUp = canInstall
            offers.why = why
        }
        return offers
    }
}

public enum CodingAISetupReply {
    /// `succeeded`.
    public static func ok(_ value: CodingAIJSON) -> Bool { value["ok"].isTrue }

    /// The refusal's own sentence.
    public static func sentence(_ value: CodingAIJSON) -> String {
        guard value.isObject, let said = value["sentence"].text else { return "That did not work." }
        return said
    }

    /// `asShellId`: the terminal the server opened.
    public static func shellId(_ value: CodingAIJSON) -> String? {
        guard value.isObject, value["ok"].isTrue else { return nil }
        return value["shellId"].text
    }

    /// `asShellOutput`.
    public static func shellOutput(_ value: CodingAIJSON) -> (shellId: String, data: String)? {
        guard value.isObject, let id = value["shellId"].text else { return nil }
        return (id, value["data"].string ?? "")
    }
}

/// `withDeadline`'s sentence for a read that never came back.
public enum CodingAIDeadline {
    /// Reading the stored servers gives up after this long (`READ_DEADLINE_MS`).
    public static let readServers: Double = 8

    public static func overdue(_ what: String, seconds: Double) -> String {
        let shown = seconds.rounded() == seconds ? String(Int(seconds)) : String(format: "%.1f", seconds)
        return "\(what) did not answer within \(shown) second\(shown == "1" ? "" : "s")."
    }
}
