import Foundation
import TerminalDeckNativeCore

public struct BackendBrowserSignInTrouble: Sendable {
    public let kind: String
    public let headline: String
    public let detail: String
    public let domains: [String]
    public var wireValue: NativeRPCValue {
        .object([.init("kind", .string(kind)), .init("headline", .string(headline)), .init("detail", .string(detail)),
            .init("domains", .array(domains.map(NativeRPCValue.string)))])
    }
}

public struct BackendBrowserSignInHandover: Sendable {
    public let url: URL
    public let domains: [String]
    public var wireValue: NativeRPCValue {
        .object([.init("url", .string(url.absoluteString)), .init("domains", .array(domains.map(NativeRPCValue.string)))])
    }
}

public struct BackendBrowserSignInCLIVersion: Sendable {
    public let command: String
    public let version: String?
    public let stale: Bool
    public let advice: String
    public var wireValue: NativeRPCValue {
        .object([.init("command", .string(command)), .init("version", version.map(NativeRPCValue.string) ?? .null),
            .init("stale", .bool(stale)), .init("advice", .string(advice))])
    }
}

/// URL diagnosis and deliberate external opening, with platform operations
/// injected. No CLI, Safari, account or credential access happens in init.
public struct BackendBrowserSignIn: Sendable {
    public let openExternal: @Sendable (URL) async throws -> Void
    /// The session/provider owner supplies the GUI-safe login-PATH runner.
    /// It must honor cancellation and bound the command to five seconds.
    public let readVersionOutput: @Sendable (String) async throws -> String?
    public init(openExternal: @escaping @Sendable (URL) async throws -> Void,
                readVersionOutput: @escaping @Sendable (String) async throws -> String?) {
        self.openExternal = openExternal; self.readVersionOutput = readVersionOutput
    }
    public static func diagnose(_ raw: String) -> BackendBrowserSignInTrouble? {
        guard let parts = URLComponents(string: raw), let host = parts.host?.lowercased(),
              host.range(of: #"(^|\.)(accounts\.google\.com|accounts\.youtube\.com)$"#, options: .regularExpression) != nil else { return nil }
        let path = parts.percentEncodedPath
        let whole = path + (parts.percentEncodedQuery.map { "?" + $0 } ?? "") + (parts.percentEncodedFragment.map { "#" + $0 } ?? "")
        let domains = ["google.com", "accounts.google.com", "youtube.com"]
        if path.range(of: "/signin/rejected", options: .caseInsensitive) != nil || whole.range(of: "disallowed_useragent", options: .caseInsensitive) != nil {
            return .init(kind: "refused", headline: "Google will not accept this sign-in from inside an app",
                detail: "Google refused this embedded sign-in. Finish it in your system browser if needed. Safari does not expose its saved website cookies to this app, so that browser session cannot be copied back automatically.", domains: domains)
        }
        if (parts.percentEncodedQuery ?? "").range(of: "flowName=GeneralOAuthLite", options: .caseInsensitive) != nil || whole.range(of: "/legacy/consent", options: .caseInsensitive) != nil {
            return .init(kind: "restricted", headline: "Google has put this sign-in on its restricted path",
                detail: "This flow can refuse embedded browsers after the password step. You can open it in your system browser. Returning to an app-owned session needs that site's supported callback flow; Safari cookies cannot be imported.", domains: domains)
        }
        return nil
    }
    public static func handoverPlan(_ raw: String, extra: [String] = []) -> BackendBrowserSignInHandover? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        let labels = host.split(separator: ".").map(String.init)
        let parent = labels.count > 2 ? labels.suffix(2).joined(separator: ".") : ""
        var domains: [String] = []
        for domain in [host, parent] + extra where !domain.isEmpty && !domains.contains(domain) { domains.append(domain) }
        return .init(url: url, domains: domains)
    }
    public func handover(_ raw: String) async throws -> BackendBrowserSignInHandover? {
        guard let plan = Self.handoverPlan(raw, extra: Self.diagnose(raw)?.domains ?? []) else { return nil }
        try Task.checkCancellation(); try await openExternal(plan.url); return plan
    }
    /// This is the source compatibility floor, not a claim about today's
    /// upstream release. Agent/CLI installation belongs to the session lane.
    public static let geminiFloor = "0.46.0"
    public func checkedAgents() async throws -> [BackendBrowserSignInCLIVersion] {
        try Task.checkCancellation()
        let output = try await readVersionOutput("gemini")
        try Task.checkCancellation()
        let version = output.flatMap(Self.parseVersion)
        let stale = version.map { Self.isBelow($0, Self.geminiFloor) } ?? false
        return [.init(command: "gemini", version: version, stale: stale,
            advice: stale ? "Google turns away builds this old after sign-in. Upgrade the installed Gemini CLI through the package manager that installed it, then sign in again." : "")]
    }
    public func agents() async throws -> [BackendBrowserSignInCLIVersion] { try await checkedAgents().filter(\.stale) }
    public static func parseVersion(_ output: String) -> String? {
        guard let match = output.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
        return String(output[match])
    }
    public static func isBelow(_ candidate: String, _ floor: String) -> Bool {
        func components(_ value: String) -> [Int] {
            let trimmed = value.hasPrefix("v") ? String(value.dropFirst()) : value
            return trimmed.split(whereSeparator: { $0 == "." || $0 == "-" }).map {
                Int($0.prefix(while: { $0.isNumber })) ?? 0
            }
        }
        let a = components(candidate), b = components(floor)
        for i in 0..<max(a.count, b.count) {
            let left = a.indices.contains(i) ? a[i] : 0, right = b.indices.contains(i) ? b[i] : 0
            if left != right { return left < right }
        }
        return false
    }
    public static let externalReturnLimitation = "The page opened in your system browser. WebKit public APIs cannot copy Safari's cookies back. Complete a supported app callback flow, or continue this sign-in in the in-app tab. No browser-cookie import was performed."
}
