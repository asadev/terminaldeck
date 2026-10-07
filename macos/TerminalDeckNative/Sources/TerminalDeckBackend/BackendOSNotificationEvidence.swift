import Foundation
import TerminalDeckNativeCore

public enum BackendOSNotificationEvidenceRules {
    public static let settingsURL = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
    public static let appleEpochOffset = 978_307_200.0
    public static func deliverySQL(bundleID: String, sinceMilliseconds: Double) -> String {
        let quoted = "'" + bundleID.replacingOccurrences(of: "'", with: "''") + "'", since = sinceMilliseconds / 1000 - appleEpochOffset - 1
        return "select datetime(r.delivered_date + 978307200, 'unixepoch', 'localtime') from record r join app a on r.app_id = a.app_id where lower(a.identifier) = lower(\(quoted)) and r.delivered_date > \(since) order by r.delivered_date desc limit 1;"
    }
}
/// os-notifications.ts's explicit read-only delivery check. Posting and click
/// delivery still belong to the existing NativeOSBridge notification delegate.
/// No private store is opened and no probe is run during construction.
public struct BackendOSNotificationEvidence: Sendable {
    public static let channels: Set<String> = ["notifications:support", "notifications:open-settings", "notifications:delivery"]
    private let home: String, file: String
    private let runner: any BackendOSCommandRunning
    private let bundleIdentifier: @Sendable () -> String?
    private let openExternal: @Sendable (String) async throws -> Bool
    private let fileExists: @Sendable (String) -> Bool
    private let now: @Sendable () -> Double, pause: @Sendable () async throws -> Void
    private let authorize: @Sendable (NativeRPCContext) throws -> Void
    public init(home: String, runner: any BackendOSCommandRunning, bundleIdentifier: @escaping @Sendable () -> String?,
                openExternal: @escaping @Sendable (String) async throws -> Bool, authorize: @escaping @Sendable (NativeRPCContext) throws -> Void,
                fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 },
                pause: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(700)) }) {
        self.home = home; self.runner = runner; self.bundleIdentifier = bundleIdentifier; self.openExternal = openExternal; self.authorize = authorize
        self.fileExists = fileExists; self.now = now; self.pause = pause
        file = URL(fileURLWithPath: home).appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db").path
    }
    public func support() -> NativeRPCValue { .object([.init("settingsPane", .bool(true)), .init("deliveryReadable", .bool(fileExists(file))), .init("platform", .string("darwin"))]) }
    public func openSettings() async -> NativeRPCValue {
        do { let opened = try await openExternal(BackendOSNotificationEvidenceRules.settingsURL); return opened ? .object([.init("opened", .bool(true))]) : .object([.init("opened", .bool(false)), .init("message", .string("The settings page would not open: macOS refused the URL."))]) }
        catch { return .object([.init("opened", .bool(false)), .init("message", .string("The settings page would not open: " + error.localizedDescription))]) }
    }
    public func delivery(since: Double?) async throws -> NativeRPCValue {
        func answer(_ verdict: String, at: String? = nil, detail: String? = nil) -> NativeRPCValue { .object([.init("verdict", .string(verdict)), .init("at", at.map(NativeRPCValue.string) ?? .null), .init("detail", detail.map(NativeRPCValue.string) ?? .null)]) }
        guard fileExists(file) else { return answer("unknown", detail: "This Mac has no notification store at the expected path.") }
        guard let id = bundleIdentifier(), !id.isEmpty else { return answer("unknown", detail: "The app could not read its own bundle identifier.") }
        let since = since.flatMap { $0.isFinite ? $0 : nil } ?? now(), sql = BackendOSNotificationEvidenceRules.deliverySQL(bundleID: id, sinceMilliseconds: since), deadline = now() + 9500
        var error: String?
        repeat {
            try Task.checkCancellation()
            do {
                let value = try await runner.run(command: "/usr/bin/sqlite3", arguments: ["-readonly", file, sql], environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home], cwd: home, timeoutMilliseconds: 4000, maximumBytes: 64 * 1024)
                if value.ok { let at = value.stdout.trimmingCharacters(in: .whitespacesAndNewlines); if !at.isEmpty { return answer("delivered", at: at) }; error = nil }
                else { error = value.stderr.isEmpty ? "sqlite3 exited \(value.exitCode)" : String(value.stderr.prefix(300)) }
            } catch is CancellationError { throw CancellationError() }
            catch let failure { error = failure.localizedDescription }
            if now() >= deadline { break }; try await pause()
        } while true
        return error.map { answer("unknown", detail: "The notification store could not be read: " + $0) } ?? answer("absent")
    }
    public func invoke(_ channel: String, args: [NativeRPCValue], context: NativeRPCContext) async throws -> NativeRPCValue {
        guard Self.channels.contains(channel) else { throw NativeRPCError(code: "unavailable", message: "The native notification evidence channel is not registered.") }
        try authorize(context)
        guard context.caller == .nativeApp || context.caller == .internalEngine else { throw NativeRPCError(code: "access-denied", message: "A guest cannot inspect this Mac's notification delivery store.") }
        switch channel { case "notifications:support": return support(); case "notifications:open-settings": return await openSettings(); default: return try await delivery(since: args.first?.number) }
    }
}
