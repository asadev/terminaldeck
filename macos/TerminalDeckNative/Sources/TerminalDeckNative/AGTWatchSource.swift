import AppKit
import Foundation
import TerminalDeckNativeCore

/// AGT: At work's source filter and the glue for agents in other apps.
enum AGTWatchSource: String, CaseIterable {
    case all, terminalDeck, other
    var title: String { switch self { case .all: "All"; case .terminalDeck: "Terminal Deck"; case .other: "Other apps" } }

    static let prefix = "device:"
    static let listChannel = "agents-device:list"
    static let readChannel = "agents-device:read"

    /// An agent in another app as an At work row (kind "device"; the app's name where the machine goes).
    static func row(_ agent: AGTDeviceAgent) -> AWWatchAgent? {
        AWWatchAgent.decode(.object([.init("id", .string(prefix + agent.id)), .init("sourceID", .string(agent.id)), .init("kind", .string("device")),
            .init("name", .string(agent.displayName)), .init("provider", .string(agent.ai)), .init("project", .string(agent.project)),
            .init("machineName", .string(agent.app.name)), .init("sessionID", agent.sessionID.map(NativeRPCValue.string) ?? .null),
            .init("state", .string(agent.state.rawValue)), .init("action", .string(agent.lastLine ?? agent.state.label)),
            .init("pid", .number(Double(agent.pid))), .init("sourceApp", .string(agent.app.name)),
            .init("since", .number(agent.startedAt * 1000)), .init("updatedAt", agent.lastAt.map(NativeRPCValue.number) ?? .null)]))
    }

    /// "Open in its app": brings that app forward, only on the person's click. Nothing is typed or sent.
    @MainActor static func bringForward(_ agent: AGTDeviceAgent) {
        if let pid = agent.app.pid, let app = NSRunningApplication(processIdentifier: pid) { NativeFront.onlyForPerson("Open in its app") { app.activate() }; return }
        if let path = agent.app.bundlePath { NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init()) }
    }

    @MainActor static func copyResume(_ agent: AGTDeviceAgent) {
        guard let id = agent.sessionID,
              let resume = AGTShellAgents.resumeCommand(provider: agent.ai, conversationID: id) else { return }
        let command = agent.project.isEmpty ? resume : "cd " + AGTDeviceDetect.shellQuote(agent.project) + " && " + resume
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    @MainActor static func icon(_ agent: AGTDeviceAgent) -> NSImage? {
        guard let path = agent.app.bundlePath, FileManager.default.fileExists(atPath: path) else { return nil }
        return NSWorkspace.shared.icon(forFile: path)
    }
}

/// Follows one file's writes (the selected conversation) with a kqueue vnode source. No polling.
@MainActor
final class AGTFileWatch {
    let path: String
    private var source: DispatchSourceFileSystemObject?
    private var pending = false
    init?(path: String, changed: @escaping @MainActor () -> Void) {
        self.path = path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.pending else { return }
                self.pending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MainActor.assumeIsolated { self.pending = false; changed() } }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }
    func stop() { source?.cancel(); source = nil }
}

/// When to re-read other apps' agents, only while At work is on screen: app launches and
/// quits, Claude Code's session records and Codex's conversation folder changing.
/// The engine owns the visible-only resource clock. There is no UI timer.
@MainActor
final class AGTDeviceWatch {
    private var observers: [NSObjectProtocol] = []
    private var folders: [DispatchSourceFileSystemObject] = []
    private var pending = false
    private var refresh: (@MainActor () -> Void)?
    private let home: String
    init(home: String = NSHomeDirectory()) { self.home = home }

    static func folderPaths(home: String, date: Date = Date()) -> [String] {
        let day = DateFormatter(); day.dateFormat = "yyyy/MM/dd"; day.locale = Locale(identifier: "en_US_POSIX")
        let parts = day.string(from: date).split(separator: "/")
        var paths = [home, home + "/.claude", home + "/.claude/sessions", home + "/.codex", home + "/.codex/sessions"]
        var path = home + "/.codex/sessions"
        for part in parts { path += "/" + part; paths.append(path) }
        return paths
    }

    func start(_ refresh: @escaping @MainActor () -> Void) {
        guard self.refresh == nil else { return }
        self.refresh = refresh
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.soon() } })
        }
        armFolders()
    }

    private func armFolders() {
        folders.forEach { $0.cancel() }; folders.removeAll()
        // Parents catch the first conversation and new day/month/year folders.
        for folder in Self.folderPaths(home: home) {
            let fd = open(folder, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.soon() } }
            source.setCancelHandler { close(fd) }
            source.resume()
            folders.append(source)
        }
    }

    private func soon() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.refresh != nil else { return }
                self.pending = false; self.armFolders(); self.refresh?()
            }
        }
    }

    func stop() {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        folders.forEach { $0.cancel() }
        folders.removeAll()
        pending = false
        refresh = nil
    }
}
