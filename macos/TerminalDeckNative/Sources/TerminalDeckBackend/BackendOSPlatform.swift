import Foundation
import Darwin
import TerminalDeckNativeCore

/// The remaining macOS platform decisions from platform/host, login-env,
/// credential-store and tailscale. Windows/WSL policy remains in the server.
public enum BackendOSPlatform {
    public static let platform = "darwin"
    public static let machineNoun = "Mac"
    public static func machineName(_ hostname: String = ProcessInfo.processInfo.hostName) -> String {
        hostname.replacingOccurrences(of: #"\.local$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func loginEnvironmentNamesSpec(environment: [String: String]) -> (command: String, arguments: [String]) {
        (environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh",
         ["-lic", #"printenv | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p'"#])
    }
    public static func parseEnvironmentNames(_ stdout: String) -> Set<String> {
        Set(stdout.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil })
    }
    public static func environmentNames(runner: BackendCommandRunner, environment: [String: String], home: String) async throws -> Set<String> {
        let spec = loginEnvironmentNamesSpec(environment: environment)
        let result = try await runner.run(command: spec.command, arguments: spec.arguments, environment: environment, cwd: home, timeoutMilliseconds: 5_000)
        guard result.succeeded else { throw NativeRPCError(code: "unavailable", message: "The login shell would not report its environment variable names.") }
        return parseEnvironmentNames(result.output)
    }
    public static let tailscaleCandidates = ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/bin/tailscale"]
    public static func findTailscale(loginPath: String) -> String? {
        BackendNativeProviders.lookup("tailscale", path: loginPath) ?? tailscaleCandidates.first { BackendNativeProviders.lookup($0, path: loginPath) != nil }
    }
    public static let profileIsolation: NativeRPCValue = .object([
        .init("store", .string("macos-keychain")), .init("isolated", .bool(true)),
        .init("note", .string("Logins are kept in the macOS Keychain under a name derived from this profile’s config directory, so profiles cannot overwrite each other’s login, and deleting this profile’s files does not sign it out."))])
    public static let reachability: NativeRPCValue = .object([
        .init("kind", .string("macos")), .init("headline", .string("Handled by the desktop build on this Mac, not here.")),
        .init("detail", .array([
            .string("Terminal Deck’s desktop build holds the wake lock and watches the battery, and it can do both from a window that is already running. A headless host on the same machine would be a second thing holding the same lock."),
            .string("Run the headless host here for what it is good at — a machine with no screen, or one you drive entirely from a phone — and leave staying-awake to the app.")
        ])), .init("steps", .array([])), .init("atRisk", .bool(false))])
}

/// user-data.ts: display names must not change the persistent app identity.
/// Choosing the root is a pure operation; this never opens the live data folder.
public enum BackendOSUserData {
    public static func root(home: URL, arguments: [String], current: URL? = nil) -> URL {
        if let override = NativePlatformPaths.userDataFlag(arguments) {
            return URL(fileURLWithPath: override).standardizedFileURL
        }
        if let current, current.lastPathComponent == "terminaldeck" { return current }
        return home.appendingPathComponent("Library/Application Support/terminaldeck", isDirectory: true)
    }
}
