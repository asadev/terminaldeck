import Foundation

/// The machines this desktop dialled — "Machines you can reach" and the code
/// entry beside "Add another computer" — the native screen's pure half: the
/// Swift reading of `machines/types.ts`, `machines/MachineLinks.tsx` and
/// `machines/CodeEntry.tsx`, rule for rule. Channels: `machines:list`, the
/// `machines:state` push, `machines:pair`, `machines:connect`,
/// `machines:disconnect`, `machines:forget`, `machines:drive-windows`,
/// `machines:ports`, `machines:open`.

public enum MachineLinkPhase: String, Sendable, Equatable {
    case offline, connecting, awaitingApproval = "awaiting-approval", online, error

    /// `STATE_LABEL`.
    public var label: String {
        switch self {
        case .offline: "Not connected"
        case .connecting: "Connecting"
        case .awaitingApproval: "Waiting to be approved"
        case .online: "Connected"
        case .error: "Cannot connect"
        }
    }
}

public struct PairedMachine: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var fingerprint: String
    public var platform: String
    public var drivesWindows: Bool

    public init(id: String, name: String, fingerprint: String = "", platform: String = "", drivesWindows: Bool = false) {
        self.id = id
        self.name = name
        self.fingerprint = fingerprint
        self.platform = platform
        self.drivesWindows = drivesWindows
    }
}

public struct MachineSessionRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var cwd: String
    public var status: String
}

public struct MachinePort: Equatable, Sendable, Identifiable {
    public var port: Int
    public var process: String
    public var guessed: Bool
    public var id: Int { port }

    public init(port: Int, process: String = "", guessed: Bool = false) {
        self.port = port
        self.process = process
        self.guessed = guessed
    }
}

public struct MachineLink: Equatable, Sendable, Identifiable {
    public var id: String
    public var phase: MachineLinkPhase
    public var reason: String?
    public var sessions: [MachineSessionRow]
    public var capabilities: [String]
    public var ports: [MachinePort]
    public var hostPlatform: String
    public var hostVersion: String
    /// `desktop`, `headless`, or nil.
    public var hostKind: String?

    public init(id: String, phase: MachineLinkPhase = .offline, reason: String? = nil, sessions: [MachineSessionRow] = [],
                capabilities: [String] = [], ports: [MachinePort] = [], hostPlatform: String = "", hostVersion: String = "", hostKind: String? = nil) {
        self.id = id
        self.phase = phase
        self.reason = reason
        self.sessions = sessions
        self.capabilities = capabilities
        self.ports = ports
        self.hostPlatform = hostPlatform
        self.hostVersion = hostVersion
        self.hostKind = hostKind
    }
}

public struct MachinesView: Equatable, Sendable {
    public var machines: [PairedMachine]
    public var links: [MachineLink]
    /// What this desktop is called, or empty.
    public var here: String
    /// Why pairing is not possible here (another app owns the identity), or nil.
    public var blocked: String?

    public static let empty = MachinesView(machines: [], links: [], here: "", blocked: nil)

    public init(machines: [PairedMachine], links: [MachineLink], here: String, blocked: String?) {
        self.machines = machines
        self.links = links
        self.here = here
        self.blocked = blocked
    }

    /// `asView`: an unreadable reply is an empty one.
    public init(json: Any?) {
        guard let row = json as? [String: Any] else { self = .empty; return }
        func text(_ value: Any?) -> String { value as? String ?? "" }
        func whole(_ value: Any?) -> Int? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let double = number.doubleValue
            return double.isFinite && double == double.rounded() ? Int(double) : nil
        }
        machines = (row["machines"] as? [Any] ?? []).compactMap { entry in
            guard let m = entry as? [String: Any], let id = m["id"] as? String, !id.isEmpty else { return nil }
            return PairedMachine(id: id, name: text(m["name"]), fingerprint: text(m["fingerprint"]), platform: text(m["platform"]),
                                 drivesWindows: m["drivesWindows"] as? Bool == true)
        }
        links = (row["links"] as? [Any] ?? []).compactMap { entry in
            guard let l = entry as? [String: Any], let id = l["id"] as? String, !id.isEmpty else { return nil }
            let sessions: [MachineSessionRow] = (l["sessions"] as? [Any] ?? []).compactMap { s in
                guard let s = s as? [String: Any], let id = s["id"] as? String, !id.isEmpty else { return nil }
                return MachineSessionRow(id: id, title: text(s["title"]), cwd: text(s["cwd"]), status: text(s["status"]))
            }
            let ports: [MachinePort] = (l["ports"] as? [Any] ?? []).compactMap { p in
                guard let p = p as? [String: Any], let port = whole(p["port"]), (1...65535).contains(port) else { return nil }
                return MachinePort(port: port, process: text(p["process"]), guessed: p["guessed"] as? Bool == true)
            }
            let kind = l["hostKind"] as? String
            return MachineLink(id: id, phase: MachineLinkPhase(rawValue: text(l["state"])) ?? .offline,
                               reason: (l["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }, sessions: sessions,
                               capabilities: (l["capabilities"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty },
                               ports: ports, hostPlatform: text(l["hostPlatform"]), hostVersion: text(l["hostVersion"]),
                               hostKind: kind == "desktop" || kind == "headless" ? kind : nil)
        }
        here = text(row["here"])
        blocked = (row["blocked"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `linkFor`: the link, or a quiet offline one when the view has none for this machine.
    public func link(for id: String) -> MachineLink {
        links.first { $0.id == id } ?? MachineLink(id: id)
    }
}

public enum MachinesRules {
    /// `machineNoun` for a far machine's platform.
    public static func noun(_ platform: String) -> String {
        switch platform {
        case "darwin": "Mac"
        case "win32": "PC"
        case "linux": "machine"
        default: "desktop"
        }
    }

    /// The noun for a row: the link's own platform when it said, else the stored one.
    public static func noun(_ machine: PairedMachine, _ link: MachineLink) -> String {
        noun(link.hostPlatform.isEmpty ? machine.platform : link.hostPlatform)
    }

    /// `version 0.18.7 · server`
    public static func versionLine(_ link: MachineLink) -> String? {
        guard !link.hostVersion.isEmpty else { return nil }
        let kind = link.hostKind.map { $0 == "headless" ? " · server" : " · desktop" } ?? ""
        return "version \(link.hostVersion)\(kind)"
    }

    /// The reason line: the approval it waits for, or the link's own words.
    public static func reasonLine(_ machine: PairedMachine, _ link: MachineLink, thisMachine: String = "this Mac") -> String? {
        if link.phase == .awaitingApproval {
            return "Approve \(thisMachine) on \(machine.name), under Remote. It will connect by itself once you have."
        }
        return link.reason
    }

    /// `…/two/last` for a long path.
    public static func shortPath(_ cwd: String) -> String {
        let parts = cwd.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        guard parts.count > 2 else { return cwd }
        return "…/\(parts.suffix(2).joined(separator: "/"))"
    }

    /// `3000 · node`, or `3000 · unknown process`.
    public static func portLabel(_ port: MachinePort) -> String {
        port.process.isEmpty || port.guessed ? "\(port.port) · unknown process" : "\(port.port) · \(port.process)"
    }

    /// Whether the "act on browser windows" tick is on but cannot be used by that build yet.
    public static func windowsMuted(_ machine: PairedMachine, _ link: MachineLink) -> Bool {
        machine.drivesWindows && link.phase == .online && !link.capabilities.contains("windows")
    }

    /// The tab id a session on another machine is opened by (`machineTabId`).
    public static func tabId(machineId: String, sessionId: String) -> String { "machine \(machineId) \(sessionId)" }

    /// `machines:pair`'s answer: nil when it paired, else the sentence.
    public static func pairFailure(_ raw: Any?) -> String? {
        guard let row = raw as? [String: Any] else { return "This machine gave no answer." }
        if row["ok"] as? Bool == true { return nil }
        let message = row["message"] as? String ?? ""
        return message.isEmpty ? "That did not work, and this machine did not say why." : message
    }
}

/// The six-box code field (`CodeEntry.tsx`).
public enum CodeEntryRules {
    public static let length = 6

    /// The six digits, ignoring spaces and dashes; nil for anything else (`normaliseCode`).
    public static func normalise(_ typed: String) -> String? {
        var digits = ""
        for character in typed.prefix(256) {
            if character.isASCII, character.isNumber {
                digits.append(character)
                if digits.count > length { return nil }
                continue
            }
            if character.isASCII, character.isLetter { return nil }
        }
        return digits.count == length ? digits : nil
    }

    /// A character as the code has it, or nil when it cannot be one.
    public static func symbol(_ character: Character) -> String? {
        normalise(String(repeating: character, count: length)).map { String($0.prefix(1)) }
    }

    /// What typing (or pasting) `raw` into box `at` leaves, and which box takes the caret.
    public static func typed(into digits: String, at: Int, raw: String) -> (digits: String, focus: Int) {
        let accepted = raw.compactMap(symbol)
        guard !accepted.isEmpty else { return (digits, at) }
        var padded = Array(digits.padding(toLength: length, withPad: " ", startingAt: 0))
        if digits.count > length { padded = Array(digits.prefix(length)) }
        for (offset, symbol) in accepted.enumerated() where at + offset < length {
            padded[at + offset] = Character(symbol)
        }
        var next = String(padded)
        while next.hasSuffix(" ") { next.removeLast() }
        return (next, min(at + accepted.count, length - 1))
    }

    /// The characters a change added to a box that already held `previous`.
    public static func added(by raw: String, previous: String) -> String {
        if previous.isEmpty || raw.count <= 1 { return raw }
        if raw.hasPrefix(previous) { return String(raw.dropFirst(previous.count)) }
        if raw.hasSuffix(previous) { return String(raw.dropLast(previous.count)) }
        return raw
    }

    public static func digit(_ digits: String, at index: Int) -> String {
        guard index < digits.count else { return "" }
        let character = digits[digits.index(digits.startIndex, offsetBy: index)]
        return character == " " ? "" : String(character)
    }
}
