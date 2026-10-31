import Foundation

/// "Attach browser" / "Connect browser": the engine's bind menu as data
/// (`browser:bind-menu-items`, main/browser-binding-ipc.ts `bindMenuRows`) — the
/// same rows, order and words as the Electron menu it pops in the Electron window.
public struct BindMenuRow: Equatable, Sendable {
    public enum Kind: String, Sendable { case item, checkbox, separator }
    /// What choosing it does, and the channel that carries it back.
    public enum Act: Equatable, Sendable {
        case bind(tabId: String)
        case unbind(tabId: String)
        case newWindow
    }

    public let kind: Kind
    public let label: String
    public let enabled: Bool
    public let checked: Bool
    public let act: Act?

    public init(kind: Kind, label: String, enabled: Bool, checked: Bool, act: Act?) {
        self.kind = kind; self.label = label; self.enabled = enabled; self.checked = checked; self.act = act
    }

    /// The answer, read strictly: rows it cannot read are dropped; nil when it is not a list.
    public static func list(_ raw: CodingAIJSON) -> [BindMenuRow]? {
        guard let rows = raw.array else { return nil }
        return rows.compactMap { row in
            guard row.isObject, let kind = Kind(rawValue: row["type"].string ?? "") else { return nil }
            if kind == .separator { return BindMenuRow(kind: .separator, label: "", enabled: false, checked: false, act: nil) }
            guard let label = row["label"].string else { return nil }
            var act: Act?
            switch row["act"]["kind"].string {
            case "bind": act = row["act"]["tabId"].text.map { .bind(tabId: $0) }
            case "unbind": act = row["act"]["tabId"].text.map { .unbind(tabId: $0) }
            case "new-window": act = .newWindow
            default: act = nil
            }
            return BindMenuRow(kind: kind, label: label, enabled: row["enabled"].isTrue && act != nil,
                               checked: row["checked"].isTrue, act: act)
        }
    }

    /// The channel and argument a press sends (`ipcMain.on` listeners in the engine).
    /// `browser:unbind` takes the bare tab id; the other two take an object.
    public static func command(_ act: Act, sessionId: String, machineId: String) -> (channel: String, arg: CodingAIJSON) {
        switch act {
        case .bind(let tabId):
            return ("browser:bind", .object(["tabId": .string(tabId), "sessionId": .string(sessionId), "machineId": .string(machineId)]))
        case .unbind(let tabId):
            return ("browser:unbind", .string(tabId))
        case .newWindow:
            return ("browser:bind-new-window", .object(["sessionId": .string(sessionId), "machineId": .string(machineId)]))
        }
    }

    /// `bindKey`: which session (and machine) a rail or strip id stands for — a remote
    /// session's `machine <machineId> <sessionId>`, a server shell's (shell id, server id),
    /// or a local session as itself. Nil for a server terminal whose shell is not open yet.
    public static func key(tabId: String, server: ServerTabInfo?) -> (sessionId: String, machineId: String)? {
        let prefix = "machine "
        if tabId.hasPrefix(prefix) {
            let rest = tabId.dropFirst(prefix.count)
            if let cut = rest.firstIndex(of: " "), cut != rest.startIndex, rest.index(after: cut) != rest.endIndex {
                return (String(rest[rest.index(after: cut)...]), String(rest[..<cut]))
            }
        }
        if let server {
            guard let shell = server.shellId, !shell.isEmpty else { return nil }
            return (shell, server.serverId)
        }
        return (tabId, "")
    }
}
