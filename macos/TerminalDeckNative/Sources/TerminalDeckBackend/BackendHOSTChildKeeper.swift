import Foundation
import TerminalDeckNativeCore

/// Scratch helpers remain in their app's process tree and never enter launchd's background-item database.
final class BackendHOSTChildKeeper: @unchecked Sendable {
    private static let shared = BackendHOSTChildKeeper()
    private let lock = NSLock()
    private var children: [Process] = []

    static func start(helper: URL, arguments: [String], data: URL) throws {
        let child = Process()
        child.executableURL = helper
        child.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment[NativeLaunchSwitches.hostChild] = "1"
        environment[NativeLaunchSwitches.dataFolder] = data.path
        environment[NativeLaunchSwitches.agentConfigReadOnly] = "1"
        environment[NativeLaunchSwitches.noSystemPrompts] = "1"
        child.environment = environment
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        shared.lock.withLock {
            shared.children.removeAll { !$0.isRunning }
            shared.children.append(child)
        }
    }
}
