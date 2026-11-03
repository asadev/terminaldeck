import Foundation
import TerminalDeckNativeCore

/// Device Hub actions use the existing platform executor. Construction never
/// reads a real device or starts an engine; tests pass a stub executor and home.
public struct BackendFIXESDeviceManagement: Sendable {
    public enum Action: String, Equatable, Sendable { case rename, reset, delete, restart, coldStart }
    public let platform: BackendAppDevicePlatform
    private let moveItem: @Sendable (URL, URL) throws -> Void
    public init(platform: BackendAppDevicePlatform,
                moveItem: @escaping @Sendable (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) {
        self.platform = platform; self.moveItem = moveItem
    }

    private func refused(_ message: String) -> NativeRPCError {
        NativeRPCError(code: "device-refused", message: message)
    }
    private func listed(_ id: String, in rows: [NativeRPCValue]) throws -> NativeRPCValue {
        _ = try BackendAppDeviceChannels.deviceID(.string(id))
        guard let row = rows.first(where: { $0["id"].string == id }) else {
            throw refused("That device is no longer listed. Refresh devices and try again.")
        }
        guard ["simulator", "emulator"].contains(row["kind"].string ?? "") else {
            throw refused("A phone on a cable is managed on the phone itself.")
        }
        return row
    }
    private func avdName(_ id: String) async throws -> String {
        let name: String
        if id.hasPrefix("avd:") { name = String(id.dropFirst(4)) }
        else if id.hasPrefix("android:emulator-") { name = await platform.avdName(String(id.dropFirst(8))) }
        else { throw refused("That device has no emulator folder.") }
        guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$"#, options: .regularExpression) != nil,
              name != ".", name != ".." else { throw refused("The emulator did not supply a safe folder name.") }
        return name
    }
    private func iosUDID(_ id: String) throws -> String {
        let value = String(id.dropFirst(4))
        guard id.hasPrefix("ios:"), UUID(uuidString: value) != nil else {
            throw refused("That is not an iOS simulator id.")
        }
        return value
    }
    private var avdRoot: URL {
        if let folder = platform.environment["ANDROID_AVD_HOME"], !folder.isEmpty { return URL(fileURLWithPath: folder, isDirectory: true) }
        if let folder = platform.environment["ANDROID_USER_HOME"], !folder.isEmpty { return URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent("avd", isDirectory: true) }
        return URL(fileURLWithPath: platform.home, isDirectory: true).appendingPathComponent(".android/avd", isDirectory: true)
    }
    public func folder(_ id: String, rows: [NativeRPCValue]) async throws -> URL {
        _ = try listed(id, in: rows)
        let home = URL(fileURLWithPath: platform.home, isDirectory: true)
        if id.hasPrefix("ios:") {
            let root = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true)
            let candidate = root
                .appendingPathComponent(try iosUDID(id), isDirectory: true)
            guard candidate.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath() else {
                throw refused("That simulator folder points outside the listed device folder.")
            }
            return candidate
        }
        let root = avdRoot, name = try await avdName(id)
        let ini = root.appendingPathComponent(name + ".ini")
        guard ini.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath() else {
            throw refused("That emulator record points outside the listed device folder.")
        }
        let configured = (try? String(contentsOf: ini, encoding: .utf8))?.split(separator: "\n")
            .first(where: { $0.hasPrefix("path=") }).map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines) }
        let candidate = configured.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? root.appendingPathComponent(name + ".avd", isDirectory: true)
        guard candidate.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath() else {
            throw refused("That emulator folder points outside the listed device folder.")
        }
        return candidate
    }
    private func run(_ executable: String, _ arguments: [String]) async throws {
        // Bounded even when the child's end is never reported (devices freeze, 26 Oct).
        let answer = await BackendAppDeviceDeadline.command(platform.executor, executable, arguments: arguments, environment: platform.environment,
            cwd: platform.home, timeoutMilliseconds: 60_000, maximumBytes: 256 * 1024, graceMilliseconds: platform.commandGraceMilliseconds)
        guard answer.ok else {
            let message = answer.stderr.split(separator: "\n").first.map(String.init) ?? "The device change did not finish."
            throw NativeRPCError(code: "device-fault", message: message)
        }
    }
    private func avdManager() throws -> String {
        guard let sdk = platform.androidSDK() else { throw refused("Android Studio’s tools are not installed on this Mac.") }
        let root = URL(fileURLWithPath: sdk)
        var candidates = [root.appendingPathComponent("cmdline-tools/latest/bin/avdmanager"), root.appendingPathComponent("tools/bin/avdmanager")]
        let versions = root.appendingPathComponent("cmdline-tools", isDirectory: true)
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: versions.path)) ?? []).sorted().reversed() {
            candidates.append(versions.appendingPathComponent(name).appendingPathComponent("bin/avdmanager"))
        }
        guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw refused("Android Studio’s device manager is not installed on this Mac.")
        }
        return tool.path
    }
    public func perform(_ action: Action, id: String, name: String? = nil, confirmed: Bool = false,
                        rows: [NativeRPCValue]) async throws -> NativeRPCValue {
        let row = try listed(id, in: rows)
        if [.reset, .delete].contains(action), !confirmed { throw refused("Confirm \(action == .reset ? "resetting" : "deleting") \(row["name"].string ?? id) first.") }
        if action == .restart || action == .coldStart {
            let ios = id.hasPrefix("ios:")
            // iOS has no snapshot to skip: its cold start is a fresh boot (shut down first when it is on).
            if action == .restart, !["ready", "booting"].contains(row["state"].string ?? "") { throw refused("That simulator is off. Choose Start.") }
            if ios { _ = try iosUDID(id) }
            let bootID: String
            if ios { bootID = id } else { bootID = "avd:" + (try await avdName(id)) }
            if !ios { _ = try await folder(id, rows: rows) }
            let didStop = ["ready", "booting"].contains(row["state"].string ?? "")
            if didStop {
                let stopped = await platform.shutDown(id)
                guard stopped["ok"].bool == true else { throw refused(stopped["message"].string ?? "The device must be shut down first.") }
            }
            return await platform.boot(bootID, coldStart: action == .coldStart, afterShutdownID: !ios && didStop ? id : nil)
        }
        let nextName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if action == .rename {
            guard !nextName.isEmpty, nextName.utf16.count <= 120, !nextName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw refused("Use a device name between 1 and 120 characters.")
            }
        }
        let ios = id.hasPrefix("ios:")
        let udid: String, avd: String
        if ios { udid = try iosUDID(id); avd = "" }
        else { udid = ""; avd = try await avdName(id) }
        // Validate every argument/path before stopping a device. Renaming an iOS
        // simulator does not interrupt it; an Android AVD must be off to move it.
        var androidTool = ""
        if !ios && action != .reset { androidTool = try avdManager() }
        if !ios && action == .rename {
            guard nextName.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$"#, options: .regularExpression) != nil else {
                throw refused("An Android emulator name uses letters, numbers, dots, underscores and hyphens.")
            }
            let root = avdRoot
            guard !FileManager.default.fileExists(atPath: root.appendingPathComponent(nextName + ".avd").path),
                  !FileManager.default.fileExists(atPath: root.appendingPathComponent(nextName + ".ini").path) else {
                throw refused("An emulator with that name already exists. Choose another name.")
            }
        }
        let deviceFolder: URL?
        if ios { deviceFolder = nil } else { deviceFolder = try await folder(id, rows: rows) }
        if (action != .rename || !ios), ["ready", "booting"].contains(row["state"].string ?? "") {
            let stopped = await platform.shutDown(id)
            guard stopped["ok"].bool == true else { throw refused(stopped["message"].string ?? "The device must be shut down first.") }
        }
        if ios {
            let verb = action == .reset ? "erase" : action.rawValue
            try await run("xcrun", ["simctl", verb, udid] + (action == .rename ? [nextName] : []))
        } else if action == .rename {
            try await run(androidTool, ["move", "avd", "-n", avd, "-r", nextName])
        } else if action == .delete {
            try await run(androidTool, ["delete", "avd", "-n", avd])
        } else if let deviceFolder {
            return try resetAndroid(deviceFolder, id: id)
        }
        return .object([.init("ok", .bool(true)), .init("id", .string(!ios && action == .rename ? "avd:" + nextName : id))])
    }
    private func resetAndroid(_ folder: URL, id: String) throws -> NativeRPCValue {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        // Keep the hardware/config and base system image. Removing only these
        // writable artifacts makes the next ordinary start a fresh device.
        let writable = contents.filter { file in
            let name = file.lastPathComponent
            return name.hasPrefix("userdata-qemu.img") || name.hasPrefix("cache.img") || name == "snapshots" || name == "encryptionkey.img"
        }
        let backup = folder.appendingPathComponent(Self.resetPrefix + "\(UUID().uuidString).noindex", isDirectory: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: false)
        var moved: [URL] = []
        do {
            for file in writable {
                try moveItem(file, backup.appendingPathComponent(file.lastPathComponent))
                moved.append(file)
            }
        } catch {
            var restored = true
            for original in moved.reversed() {
                do { try moveItem(backup.appendingPathComponent(original.lastPathComponent), original) }
                catch { restored = false }
            }
            if !restored { throw NativeRPCError(code: "device-fault", message: "Reset did not finish. The previous data is kept in \(backup.path).") }
            throw error
        }
        // U144 (#113): the erase is done, so the old data (gigabytes) goes, with any left by earlier erases.
        // Only a copy that could not be removed is named in the result.
        for leftover in contents where leftover.lastPathComponent.hasPrefix(Self.resetPrefix) && leftover.pathExtension == "noindex" {
            try? fm.removeItem(at: leftover)
        }
        try? fm.removeItem(at: backup)
        guard fm.fileExists(atPath: backup.path) else { return .object([.init("ok", .bool(true)), .init("id", .string(id))]) }
        return .object([.init("ok", .bool(true)), .init("id", .string(id)), .init("backup", .string(backup.path))])
    }
    static let resetPrefix = "TerminalDeck Reset "
}
