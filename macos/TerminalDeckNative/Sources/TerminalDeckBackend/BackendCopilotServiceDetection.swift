import Foundation
import TerminalDeckNativeCore

/// GitHub's Copilot CLI setup probe (src/main/copilot.ts), distinct from Hoot.
public struct BackendCopilotServiceDetection: Sendable {
    public let state: String
    public let route: String?
    public let version: String?
    public let probe: BackendAppSessionProbeResult
    public let remedy: String?
    public var wireValue: NativeRPCValue {
        var fields: [NativeRPCValue.Field] = [.init("state", .string(state)), .init("route", route.map(NativeRPCValue.string) ?? .null), .init("probe", probe.wireValue)]
        if let version { fields.append(.init("version", .string(version))) }
        if let remedy { fields.append(.init("remedy", .string(remedy))) }
        return .object(fields)
    }
}
public struct BackendCopilotServiceDetector: Sendable {
    public static let id = "copilot"
    public static let binary = "copilot"
    public static let label = "GitHub Copilot"
    public static let url = "https://github.com/github/copilot-cli"
    public static let purpose = "Run GitHub Copilot CLI on this machine"
    public static let timeoutMilliseconds = 5000
    private let executor: any BackendAppSessionCommandExecuting
    private let toolProbe: BackendAppSessionToolProbe
    private let environment: [String: String]
    private let home: String
    public init(executor: any BackendAppSessionCommandExecuting = BackendAppSessionCommandExecutor(),
                environment: [String: String], home: String) {
        self.executor = executor; self.environment = environment; self.home = home
        toolProbe = .init(executor: executor, environment: environment, home: home)
    }
    public static func hasExtension(_ listing: String) -> Bool {
        BackendSharedText.matches(listing, #"(?m)(^|\s)gh-copilot(\s|$)"#) ||
            listing.range(of: "github/gh-copilot", options: .caseInsensitive) != nil
    }
    public static func signedIn(environment: [String: String], directoryEntries: [String], ghAuthenticated: Bool) -> Bool {
        ["GH_TOKEN", "GITHUB_TOKEN", "COPILOT_GITHUB_TOKEN"].contains { !BackendSharedText.trim(environment[$0] ?? "").isEmpty } ||
            directoryEntries.contains { ["config.json", "hosts.json", "credentials.json", "auth.json", "apps.json"].contains($0) } || ghAuthenticated
    }
    private func gh(_ args: [String], path: String) async -> BackendAppSessionCommandResult {
        var env = environment; env["PATH"] = path
        return await executor.run("gh", arguments: args, environment: env, cwd: home, timeoutMilliseconds: Self.timeoutMilliseconds, maximumBytes: 1024 * 1024)
    }
    public func detect(path: String) async -> BackendCopilotServiceDetection {
        let probe = await toolProbe.probe(Self.binary, path: path)
        var route: String?
        if probe.found { route = "cli" }
        else {
            let listing = await gh(["extension", "list"], path: path)
            if listing.ok && Self.hasExtension(listing.stdout) { route = "gh-extension" }
        }
        guard let route else { return .init(state: "missing", route: nil, version: nil, probe: probe, remedy: "Install the GitHub Copilot CLI, then check again.") }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: URL(fileURLWithPath: home).appendingPathComponent(".copilot").path)) ?? []
        let signal = Self.signedIn(environment: environment, directoryEntries: entries, ghAuthenticated: false)
        let authed: Bool
        if signal { authed = true } else { authed = await gh(["auth", "status"], path: path).ok }
        let resolved = probe.output.components(separatedBy: "\n").map { BackendSharedText.trim($0) }.first { !$0.isEmpty }
        let version = route == "cli" ? await toolProbe.version(Self.binary, path: path, resolved: resolved) : nil
        let remedy = authed ? nil : route == "gh-extension"
            ? "Installed as a `gh` extension, but `gh` is not signed in. Run `gh auth login`."
            : "Installed, but no GitHub sign-in was found. Run `copilot` and use /login — it never happens in this window."
        return .init(state: authed ? "ready" : "installed-not-authed", route: route, version: version, probe: probe, remedy: remedy)
    }
    public static func toolStatus(_ detection: BackendCopilotServiceDetection) -> NativeRPCValue {
        var value = NativeRPCValue.object([.init("id", .string(id)), .init("label", .string(label)), .init("state", .string(detection.state)),
            .init("purpose", .string(purpose)), .init("url", .string(url)), .init("required", .bool(false))])
        if let version = detection.version { value = value.setting("version", .string(version)) }
        if let remedy = detection.remedy { value = value.setting("remedy", .string(remedy)) }
        return value
    }
}
