import Foundation
import TerminalDeckNativeCore

/// tailscale-serve.ts: inspect incremental output before waiting for exit.
public struct BackendRemoteServeTailscale: Sendable {
    private let tailnet: BackendRemoteServeTailnet
    public init(tailnet: BackendRemoteServeTailnet) { self.tailnet = tailnet }
    public func serveOn(httpsPort: Int, localPort: Int) async -> NativeRPCValue {
        guard await tailnet.find() != nil else { return Self.failure("The tailscale command could not be found on this Mac.") }
        await serveOff(httpsPort: httpsPort)
        let result = await tailnet.execute(["serve", "--bg", "--https=\(httpsPort)", "http://127.0.0.1:\(localPort)"], timeout: 15_000,
            stopWhen: { out, err in Self.readOutput(stdout: out, stderr: err) != nil })
        if let known = Self.readOutput(stdout: result.stdout, stderr: result.stderr) { return known }
        let said = (result.stderr.isEmpty ? result.stdout : result.stderr).remoteServeTrimmed
        if result.spawnError != nil { return Self.failure(Self.describe(said), detail: String(said.prefix(400))) }
        if result.code == -1 { return Self.failure("Tailscale did not answer within 15 seconds, so the direct tailnet address is not available.", detail: String((result.stdout + result.stderr).remoteServeTrimmed.prefix(400))) }
        if result.code == 0 { return Self.failure("Tailscale accepted the proxy but did not report a URL for it.", detail: String(result.stdout.remoteServeTrimmed.prefix(400))) }
        return Self.failure(Self.describe(said), detail: String(said.prefix(400)))
    }
    public func serveOff(httpsPort: Int) async { _ = await tailnet.execute(["serve", "--https=\(httpsPort)", "off"], timeout: 10_000) }
    public static func readOutput(stdout: String, stderr: String) -> NativeRPCValue? {
        if stdout.range(of: #"\bserve is not enabled on your tailnet\b"#, options: [.regularExpression, .caseInsensitive]) != nil || stderr.range(of: #"\bserve is not enabled on your tailnet\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            let combined = stdout + stderr
            let link = match(#"https://login\.tailscale\.com/f/serve\?\S+"#, in: combined)
            let remedy = link.map { " Turn it on at \($0)" } ?? " Turn it on in the Tailscale admin console"
            return failure("Serve is switched off for this tailnet, so Tailscale will not put a proxy in front of the app.\(remedy), then try again.", detail: String(combined.remoteServeTrimmed.prefix(400)))
        }
        if let url = match(#"https://\S+"#, in: stdout) {
            let normalized = url.replacingOccurrences(of: #"/+$"#, with: "/", options: .regularExpression)
            return .object([.init("ok", .bool(true)), .init("url", .string(normalized))])
        }
        return nil
    }
    public static func describe(_ said: String) -> String {
        let lower = said.lowercased()
        if lower.contains("funnel") && lower.contains("not") { return "Tailscale refused to serve this port. Check that HTTPS Certificates are enabled for this tailnet." }
        if lower.contains("tls") || lower.contains("cert") { return "Tailscale cannot get a certificate for this Mac. Open https://login.tailscale.com/admin/dns and turn on HTTPS Certificates, then try again." }
        if lower.contains("failed to connect") || lower.contains("is tailscale running") { return "Tailscale is not running on this Mac. Start it, then try again." }
        if lower.contains("permission") || lower.contains("access denied") { return "Tailscale refused the request. Serving may be disabled for this tailnet in the admin console." }
        return "Tailscale could not put a proxy in front of this app: \(said.components(separatedBy: "\n").first?.remoteServeTrimmed ?? "")"
    }
    private static func failure(_ message: String, detail: String? = nil) -> NativeRPCValue {
        var fields: [NativeRPCValue.Field] = [.init("ok", .bool(false)), .init("message", .string(message))]
        if let detail { fields.append(.init("detail", .string(detail))) }; return .object(fields)
    }
    private static func match(_ pattern: String, in value: String) -> String? {
        value.range(of: pattern, options: .regularExpression).map { String(value[$0]) }
    }
}
