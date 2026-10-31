import Foundation
import TerminalDeckNativeCore

/// AGT: remembers the AI conversation running inside each of Terminal Deck's shell tabs,
/// by tab key, in a small file in the app's data folder, so it survives app and session-host
/// restarts. Fed by the hook events Terminal Deck already accepts for that tab's process
/// tree, and by a cheap scan of that one tab's process tree when its screen state changes
/// (for agents without hooks). Never polls. Restore reads it to resume the conversation.
public final class BackendAGTShellAgents: @unchecked Sendable {
    public static let changedEvent = "agt-shell-agents:changed"
    public static let listChannel = "agt-shell-agents:list"
    /// Days a record outlives its tab (a closed tab is never restored, so this only tidies).
    static let keepDays: Double = 30

    private let lock = NSLock()
    private let file: URL
    private let home: String
    private var records: [String: AGTShellAgent] = [:]
    private var lastScan: [String: Date] = [:]
    private let changed: @Sendable () -> Void

    public init(dataRoot: URL, home: String = NSHomeDirectory(), changed: @escaping @Sendable () -> Void = {}) {
        file = dataRoot.appendingPathComponent("agt-shell-agents.json")
        self.home = home; self.changed = changed
        if let data = try? Data(contentsOf: file), data.count < 2 * 1024 * 1024,
           let value = try? NativeRPCValue.parseJSON(data, maximumBytes: 2 * 1024 * 1024) {
            let cutoff = (Date().timeIntervalSince1970 - Self.keepDays * 86_400) * 1000
            for field in value["tabs"].fields ?? [] {
                if let record = AGTShellAgent.decode(field.value), record.updatedAt >= cutoff { records[field.key] = record }
            }
        }
    }

    // MARK: The process-wide instance (restore and the launcher read it)

    private static let registry = NSLock()
    nonisolated(unsafe) private static var installed: BackendAGTShellAgents?
    public static var current: BackendAGTShellAgents? { registry.withLock { installed } }
    public static func install(_ store: BackendAGTShellAgents?) { registry.withLock { installed = store } }

    // MARK: Reading

    public func record(tabKey: String?) -> AGTShellAgent? {
        guard let tabKey else { return nil }
        return lock.withLock { records[tabKey] }
    }
    public func all() -> [String: AGTShellAgent] { lock.withLock { records } }

    /// The restore's create input for a saved shell tab gains its AI, if one was running.
    public static func applyResume(to input: inout BackendCreateSessionInput) {
        guard input.provider == "shell", input.shellAgent == nil, let record = current?.record(tabKey: input.tabKey) else { return }
        input.shellAgent = .init(provider: record.provider, conversationId: record.conversationID, cwd: record.cwd)
    }

    /// Shell session rows gain `innerAgent` (provider and conversation), for At work and the tab icon.
    public func decorate(_ sessions: [NativeRPCValue]) -> [NativeRPCValue] {
        let known = all()
        return sessions.map { session in
            guard session["provider"].string == "shell", session["exitCode"].isNullish,
                  let key = session["tabKey"].string ?? session["id"].string, let record = known[key] else { return session }
            return session.setting("innerAgent", record.wireValue)
        }
    }

    // MARK: Changing

    /// An accepted hook event (already checked to come from this tab's own process tree).
    public func accept(_ event: BackendSessionHookEvent, session: NativeRPCValue?) {
        guard let session, session["provider"].string == "shell", AGTShellAgents.providers.contains(event.provider),
              let key = session["tabKey"].string ?? session["id"].string,
              event.payload["isSidechain"].bool != true, event.payload["is_sidechain"].bool != true else { return }
        if event.event == "SessionEnd" { apply(key, .clear); return }
        guard let id = event.cliSessionID, AGTShellAgents.resumeCommand(provider: event.provider, conversationID: id) != nil else { return }
        let current = record(tabKey: key)
        if current?.provider == event.provider && current?.conversationID == id { return }
        let cwd = event.cwd.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? session["cwd"].string ?? ""
        apply(key, .set(AGTShellAgent(provider: event.provider, conversationID: id, cwd: cwd, updatedAt: Date().timeIntervalSince1970 * 1000)))
    }

    /// Look once at one shell tab's process tree (on its screen state changing). At most every 2 s per tab.
    public func scan(session: NativeRPCValue, rootPID: Int32?, snapshot: () -> [AGTProcess] = { BackendAGTProcessTable.snapshot() }) {
        guard session["provider"].string == "shell", let key = session["tabKey"].string ?? session["id"].string else { return }
        let alive = session["exitCode"].isNullish && rootPID != nil
        let now = Date()
        let due = lock.withLock { () -> Bool in
            if let last = lastScan[key], now.timeIntervalSince(last) < 2 { return false }
            lastScan[key] = now; return true
        }
        guard due else { return }
        var found: AGTDeviceAgent?
        if alive, let rootPID {
            found = AGTShellAgents.innerAgent(root: rootPID, processes: snapshot(), files: BackendAGTDeviceScanner.files(home: home), now: now.timeIntervalSince1970)
        }
        apply(key, AGTShellAgents.change(current: record(tabKey: key), found: found, shellAlive: alive, cwd: session["cwd"].string ?? "", now: now.timeIntervalSince1970))
    }

    func apply(_ key: String, _ change: AGTShellAgents.Change) {
        let wrote = lock.withLock { () -> Bool in
            switch change {
            case .keep: return false
            case .clear: return records.removeValue(forKey: key) != nil
            case .set(let record): records[key] = record; return true
            }
        }
        guard wrote else { return }
        save()
        changed()
    }

    private func save() {
        let snapshot = all()
        let value = NativeRPCValue.object([.init("version", .number(1)),
            .init("tabs", .object(snapshot.keys.sorted().map { .init($0, snapshot[$0]!.wireValue) }))])
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(value.compact.utf8).write(to: file, options: .atomic)
    }
}
