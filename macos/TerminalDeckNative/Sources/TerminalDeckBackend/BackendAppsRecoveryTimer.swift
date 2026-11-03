import Foundation
import TerminalDeckNativeCore

/// The kernel owns the app lock, approved receipt and expiring pinned command
/// callback. This helper accepts no replacement unit bytes or foreign target.
enum BackendAppsRecoveryTimer {
    typealias Command = @Sendable (_ script: String) async throws -> BackendServersRunResult
    private enum Disk: String, Sendable { case present, absent }
    private struct Actual: Sendable {
        let fragment: String
        let load: String
        let unitFile: String
        let active: String
        let needsReload: Bool
        var enabled: Bool { unitFile == "enabled" }
        var running: Bool { active == "active" }
        var notFound: Bool { load == "not-found" && fragment.isEmpty && !enabled && !running && !needsReload }
    }

    static func capture(scope: BackendAppsRecoveryScope, unit: String, command: @escaping Command) async throws -> (enabled: Bool, active: Bool) {
        let path = try ownedPath(scope, unit)
        _ = try await disk(scope: scope, path: path, command: command)
        let actual = try await query(unit: unit, path: path, command: command)
        return (actual.enabled, actual.running)
    }

    /// Unit-file absence does not prove PID 1 forgot or stopped a timer. Every
    /// successful restoration ends with fresh named systemd properties. Runtime
    /// enablement, aliases, masks, static/indirect units and transient states are
    /// unsupported rather than compressed into a false enabled/active baseline.
    static func restore(scope: BackendAppsRecoveryScope, unit: String, enabled: Bool, active: Bool, command: @escaping Command) async throws -> Bool {
        let path = try ownedPath(scope, unit)
        do {
            let initialDisk = try await disk(scope: scope, path: path, command: command)
            let initial = try await query(unit: unit, path: path, command: command)
            if initialDisk == .absent {
                guard !enabled && !active else { return false }
                // A nonzero stop/disable can mean the unit is already gone.
                // Only fresh explicit not-found/inactive metadata can make
                // that safe; never interpret a generic error as success.
                guard try await action("stop", unit: unit, path: path, allowNotFound: initial.notFound, command: command) else { return false }
                let stopped = try await query(unit: unit, path: path, command: command)
                guard !stopped.running else { return false }
                guard try await action("disable", unit: unit, path: path, allowNotFound: stopped.notFound, command: command) else { return false }
                let disabled = try await query(unit: unit, path: path, command: command)
                guard !disabled.enabled && !disabled.running else { return false }
                guard try await run("systemctl daemon-reload", command: command) else { return false }
                guard try await disk(scope: scope, path: path, command: command) == .absent else { return false }
                let final = try await query(unit: unit, path: path, command: command)
                return final.notFound
            }

            // Captured files are restored before this step. Recheck ownership
            // after reload as well as before every state-changing request.
            guard try await run("systemctl daemon-reload", command: command) else { return false }
            guard try await disk(scope: scope, path: path, command: command) == .present else { return false }
            let loaded = try await query(unit: unit, path: path, command: command)
            guard loaded.load == "loaded", !loaded.needsReload else { return false }
            guard try await action(enabled ? "enable" : "disable", unit: unit, path: path, allowNotFound: false, command: command) else { return false }
            let installation = try await query(unit: unit, path: path, command: command)
            guard installation.load == "loaded", installation.enabled == enabled, !installation.needsReload else { return false }
            guard try await disk(scope: scope, path: path, command: command) == .present else { return false }
            guard try await action(active ? "start" : "stop", unit: unit, path: path, allowNotFound: false, command: command) else { return false }
            guard try await disk(scope: scope, path: path, command: command) == .present else { return false }
            let final = try await query(unit: unit, path: path, command: command)
            return final.load == "loaded" && final.enabled == enabled && final.running == active && !final.needsReload
        } catch { return false }
    }

    private static func ownedPath(_ scope: BackendAppsRecoveryScope, _ unit: String) throws -> String {
        guard unit == scope.resourcePrefix + "-" + scope.appID + "-backup.timer",
              unit.range(of: #"^[a-z0-9-]+-backup\.timer$"#, options: .regularExpression) != nil else {
            throw NativeRPCError(code: "access-denied", message: "That timer is outside this app's recovery scope.")
        }
        return "/etc/systemd/system/" + unit
    }

    private static func disk(scope: BackendAppsRecoveryScope, path: String, command: Command) async throws -> Disk {
        let q = BackendAppsRuntime.quote
        let marker = "# Terminal Deck managed backup for " + scope.appID
        let script = """
        set -eu
        test ! -L /etc
        test ! -L /etc/systemd
        test ! -L /etc/systemd/system
        td_timer_file=\(q(path))
        test ! -L "$td_timer_file"
        if test -e "$td_timer_file"; then
          test -f "$td_timer_file"
          grep -Fx -- \(q(marker)) "$td_timer_file" >/dev/null
          printf '%s\\n' present
        else
          printf '%s\\n' absent
        fi
        """
        let result = try await command(script)
        guard result.code == 0, !result.truncated, let found = Disk(rawValue: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw unavailable() }
        return found
    }

    private static func query(unit: String, path: String, command: Command) async throws -> Actual {
        // --all keeps empty FragmentPath/UnitFileState values. Named fields
        // avoid assuming systemctl prints properties in the requested order.
        let script = "systemctl show --no-pager --all --property=FragmentPath --property=LoadState --property=UnitFileState --property=ActiveState --property=NeedDaemonReload -- " + BackendAppsRuntime.quote(unit)
        let result = try await command(script)
        guard result.code == 0, !result.truncated, result.stdout.utf8.count <= 8192,
              !result.stdout.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 10 || $0.value == 127 }) else { throw unavailable() }
        var fields: [String: String] = [:]
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let equal = line.firstIndex(of: "=") else { throw unavailable() }
            let key = String(line[..<equal]), value = String(line[line.index(after: equal)...])
            guard ["FragmentPath", "LoadState", "UnitFileState", "ActiveState", "NeedDaemonReload"].contains(key), fields[key] == nil else { throw unavailable() }
            fields[key] = value
        }
        guard fields.count == 5, let fragment = fields["FragmentPath"], let load = fields["LoadState"],
              let unitFile = fields["UnitFileState"], let active = fields["ActiveState"], ["active", "inactive"].contains(active),
              let reload = fields["NeedDaemonReload"], ["yes", "no"].contains(reload) else { throw unavailable() }
        if load == "loaded" {
            guard fragment == path, ["enabled", "disabled"].contains(unitFile) else { throw unavailable() }
        } else if load == "not-found" {
            guard fragment.isEmpty, active == "inactive", ["", "disabled", "not-found"].contains(unitFile) else { throw unavailable() }
        } else { throw unavailable() }
        return Actual(fragment: fragment, load: load, unitFile: unitFile, active: active, needsReload: reload == "yes")
    }

    private static func action(_ verb: String, unit: String, path: String, allowNotFound: Bool, command: Command) async throws -> Bool {
        guard ["stop", "start", "enable", "disable"].contains(verb) else { return false }
        // The preceding query already verified any cached fragment identity.
        // A present on-disk file is checked again by the outer recovery flow.
        if try await run("systemctl " + verb + " -- " + BackendAppsRuntime.quote(unit), command: command) { return true }
        guard allowNotFound, verb == "stop" || verb == "disable" else { return false }
        return try await query(unit: unit, path: path, command: command).notFound
    }

    private static func run(_ script: String, command: Command) async throws -> Bool {
        let result = try await command(script)
        return result.code == 0 && !result.truncated
    }
    private static func unavailable() -> NativeRPCError {
        .init(code: "unavailable", message: "The backup timer's owned systemd state could not be verified. Its saved recovery notes were kept.")
    }
}
