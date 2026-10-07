import Foundation

/// Explicit shell identity. A service receives one context instead of guessing
/// where to write before the app has chosen its real data directory.
public struct NativePlatformPaths: Equatable, Sendable {
    public enum Platform: Equatable, Sendable { case darwin, win32, linux, other(String) }
    public let identity: UUID
    public let platform: Platform
    public let userData: String
    public let home: String
    public let downloads: String
    public let appRoot: String

    public init(platform: Platform, userData: String, home: String, downloads: String, appRoot: String, identity: UUID = UUID()) {
        self.identity = identity; self.platform = platform; self.userData = userData
        self.home = home; self.downloads = downloads; self.appRoot = appRoot
    }

    public static func node(platform: Platform, environment: [String: String], home: String,
                            appRoot: String, applicationID: String, userDataOverride: String? = nil) throws -> Self {
        guard applicationID.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
              applicationID != ".", applicationID != ".." else { throw NativeRPCError.invalidArguments("Invalid application storage id") }
        let userData: String
        if let userDataOverride {
            guard isAbsolute(userDataOverride, platform: platform) else { throw NativeRPCError.invalidArguments("The user data override must be absolute") }
            userData = join(platform: platform, [userDataOverride])
        } else {
            switch platform {
            case .darwin: userData = join(platform: platform, [home, "Library", "Application Support", applicationID])
            case .win32:
                let appData = environment["APPDATA"].flatMap { $0.isEmpty ? nil : $0 }
                    ?? join(platform: platform, [home, "AppData", "Roaming"])
                userData = join(platform: platform, [appData, applicationID])
            default:
                let xdg = environment["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
                userData = join(platform: platform, xdg.map { [$0, applicationID] } ?? [home, ".local", "share", applicationID])
            }
        }
        let downloads = platform == .linux
            ? environment["XDG_DOWNLOAD_DIR"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? join(platform: platform, [home, "Downloads"])
            : join(platform: platform, [home, "Downloads"])
        return Self(platform: platform, userData: userData, home: home, downloads: downloads, appRoot: appRoot)
    }

    public static func native(configuration: EngineConfiguration, home: URL, downloads: URL, appRoot: URL) -> Self {
        Self(platform: .darwin, userData: configuration.dataRoot.path, home: home.path, downloads: downloads.path, appRoot: appRoot.path)
    }

    public func child(_ components: String...) -> String { Self.join(platform: platform, [userData] + components) }
    public var userDataURL: URL { URL(fileURLWithPath: userData, isDirectory: true) }

    public func pathKey(in environment: [String: String]) -> String {
        if platform != .win32 { return "PATH" }
        return environment.keys.sorted().first { $0.uppercased() == "PATH" } ?? "Path"
    }
    public func environmentPath(_ environment: [String: String]) -> String { environment[pathKey(in: environment)] ?? "" }
    public func withPath(_ value: String, environment: [String: String]) -> [String: String] {
        let key = pathKey(in: environment)
        var result = environment.filter { platform == .win32 ? $0.key.uppercased() != "PATH" : $0.key != "PATH" }
        result[key] = value
        return result
    }

    public static func userDataFlag(_ arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument.hasPrefix("--user-data-dir=") {
                let value = String(argument.dropFirst("--user-data-dir=".count))
                return value.isEmpty ? nil : value
            }
            if argument == "--user-data-dir" {
                guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("-") else { return nil }
                return arguments[index + 1]
            }
        }
        return nil
    }

    private static func isAbsolute(_ path: String, platform: Platform) -> Bool {
        platform == .win32 ? path.range(of: #"^(?:[A-Za-z]:[\\/]|[\\/]{2})"#, options: .regularExpression) != nil : path.hasPrefix("/")
    }

    public static func join(platform: Platform, _ parts: [String]) -> String {
        let windows = platform == .win32
        let separator = windows ? "\\" : "/"
        let raw = parts.filter { !$0.isEmpty }.joined(separator: separator)
        let normalized = windows ? raw.replacingOccurrences(of: "/", with: "\\") : raw
        let absolute = isAbsolute(normalized, platform: platform)
        let unc = windows && normalized.hasPrefix("\\\\")
        let drive = windows && normalized.count >= 2 && normalized[normalized.index(after: normalized.startIndex)] == ":"
        var components: [String] = []
        for part in normalized.components(separatedBy: separator) where !part.isEmpty && part != "." {
            if part == "..", let last = components.last, last != "..", !(drive && components.count == 1), !(unc && components.count <= 2) {
                components.removeLast()
            } else if part != ".." || !absolute { components.append(part) }
        }
        let prefix = unc ? "\\\\" : absolute && !drive ? separator : ""
        let result = prefix + components.joined(separator: separator)
        if drive && absolute && components.count == 1 { return result + separator }
        return result.isEmpty ? (absolute ? separator : ".") : result
    }
}

/// Optional boot holder for assembled services. Reinstalling the same context
/// is harmless; choosing another shell after services have started is an error.
public actor NativePlatformPathInstallation {
    private var installed: NativePlatformPaths?
    public init() {}
    public func install(_ next: NativePlatformPaths) throws {
        guard installed == nil || installed == next else {
            throw NativeRPCError(code: "paths-conflict", message: "Two different platform path contexts were installed in one native backend")
        }
        installed = next
    }
    public func paths() throws -> NativePlatformPaths {
        guard let installed else { throw NativeRPCError(code: "paths-uninstalled", message: "Install platform paths before opening native state, profiles or logs") }
        return installed
    }
}
