import Foundation
import TerminalDeckNativeCore

/// Only confirmed device exits, never a viewer or engine connection closing.
public actor BackendAppDeviceLifecycle {
    public static let shared = BackendAppDeviceLifecycle()
    private var listeners: [UUID: @Sendable (Set<String>) async -> Void] = [:]
    public func observe(_ id: UUID, _ listener: @escaping @Sendable (Set<String>) async -> Void) { listeners[id] = listener }
    public func remove(_ id: UUID) { listeners[id] = nil }
    public func exited(_ ids: Set<String>) async { for listener in listeners.values { await listener(ids) } }
}

/// Retain only emulators started here so their process exit can free phone slots. Each runs through the
/// standard child runner (`NativeChild`) in its own process group, with no deadline: it is meant to keep running.
actor BackendAppDeviceEmulatorLauncher {
    static let shared = BackendAppDeviceEmulatorLauncher()
    private struct Child { let process: NativeChild; var ids: Set<String> }
    private var children: [UUID: Child] = [:]
    func launch(_ executable: String, arguments: [String], environment: [String: String], cwd: String, avd: String) throws -> UUID {
        let token = UUID()
        let process = try NativeChild.start(.init(URL(fileURLWithPath: executable).path, arguments, environment: environment, cwd: URL(fileURLWithPath: cwd).path,
                                                  input: .none, output: .discard, errors: .discard),
                                            exit: { _ in Task { await Self.shared.finished(token) } })
        children[token] = Child(process: process, ids: ["avd:" + avd]); return token
    }
    func identified(_ token: UUID, as id: String) { children[token]?.ids.insert(id) }
    func isRunning(_ token: UUID) -> Bool { children[token]?.process.isRunning == true }
    private func finished(_ token: UUID) async {
        guard let child = children.removeValue(forKey: token) else { return }
        // Before a serial exists, boot may try software graphics. Its final failure clears
        // the AVD reservation; an intermediate host exit must not invalidate that ticket.
        await BackendAppDeviceLifecycle.shared.exited(Set(child.ids.filter { $0.hasPrefix("android:") }))
    }
}
