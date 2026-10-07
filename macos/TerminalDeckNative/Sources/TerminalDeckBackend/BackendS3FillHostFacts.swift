import Foundation

/// Source src/main/reachability.ts: `HostFacts`, `readHostFacts`, `hostKind`, `distroFromRootPath`.
/// The reads (kernel text, path existence, `wslpath`) are injected; defaults touch the real machine
/// only for Linux, and never off Linux, exactly as the source guards them.
public struct BackendS3FillHostFacts: Equatable, Sendable {
    public var platform: String
    public var wsl: Bool
    public var distro: String?
    public var battery: Bool
    public var systemd: Bool
    public var user: String?
    public init(platform: String, wsl: Bool = false, distro: String? = nil, battery: Bool = false, systemd: Bool = false, user: String? = nil) {
        self.platform = platform; self.wsl = wsl; self.distro = distro; self.battery = battery; self.systemd = systemd; self.user = user
    }
}

public enum BackendS3FillHostKind: String, Sendable { case wsl, linuxServer = "linux-server", linuxLaptop = "linux-laptop", macos, windows }

public enum BackendS3FillReachability {
    public static func hostKind(_ facts: BackendS3FillHostFacts) -> BackendS3FillHostKind {
        if facts.wsl { return .wsl }
        if facts.platform == "darwin" { return .macos }
        if facts.platform == "win32" { return .windows }
        return facts.battery ? .linuxLaptop : .linuxServer
    }

    /// `\\wsl.localhost\Ubuntu-24.04\` (or the older `\\wsl$\`) gives the registration name; any other shape gives nil.
    public static func distroFromRootPath(_ windowsPath: String) -> String? {
        let text = windowsPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = text.range(of: #"^\\\\wsl(?:\.localhost|\$)\\([^\\]+)\\?$"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let body = String(text[match])
        let parts = body.split(separator: "\\", omittingEmptySubsequences: true)
        return parts.count == 2 ? String(parts[1]) : nil
    }

    static func user(_ environment: [String: String]) -> String? {
        for key in ["USER", "USERNAME", "LOGNAME"] { if let value = environment[key], !value.isEmpty { return value } }
        return nil
    }

    public static func readHostFacts(
        platform: String = "darwin", environment: [String: String] = ProcessInfo.processInfo.environment,
        readText: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) },
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        rootWindowsPath: () -> String? = { nil }
    ) -> BackendS3FillHostFacts {
        guard platform == "linux" else { return .init(platform: platform, user: user(environment)) }
        let named = environment["WSL_DISTRO_NAME"].flatMap { $0.isEmpty ? nil : $0 }
        let kernel = readText("/proc/version")?.lowercased() ?? ""
        let wsl = named != nil || kernel.contains("microsoft")
        return .init(platform: platform, wsl: wsl, distro: named ?? (wsl ? rootWindowsPath() : nil),
                     battery: exists("/sys/class/power_supply/BAT0") || exists("/sys/class/power_supply/BAT1"),
                     systemd: exists("/run/systemd/system"), user: user(environment))
    }
}
