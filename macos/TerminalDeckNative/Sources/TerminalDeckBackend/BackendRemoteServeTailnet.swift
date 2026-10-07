import Foundation
import Darwin
import TerminalDeckNativeCore

/// tailnet.ts Mac parsing, binary lookup, shared 3s cache and certificate API.
public actor BackendRemoteServeTailnet {
    public static let reasons: [String: String] = [
        "not-installed": "Tailscale is not installed on this Mac, so there is no tailnet address to listen on. Your phone can still reach this Mac through the relay; the tailnet is the faster, direct route. To use it, install Tailscale from https://tailscale.com/download, sign in, then try again.",
        "not-running": "Tailscale is installed but its background service is not answering. Open Tailscale from your Applications folder to start it, then try again.",
        "logged-out": "Tailscale is installed but signed out on this Mac. Click the Tailscale icon in the menu bar, choose Log in, then try again.",
        "stopped": "Tailscale is signed in but switched off on this Mac. Click the Tailscale icon in the menu bar, choose Connect, then try again.",
        "needs-approval": "This Mac is signed in but still waiting to join the tailnet. Approve it at https://login.tailscale.com/admin/machines, then try again.",
        "starting": "Tailscale is still starting up on this Mac. Give it a few seconds, watch the Tailscale icon in the menu bar, then try again.",
        "no-address": "Tailscale is running but has not given this Mac a tailnet address yet. Click the Tailscale icon in the menu bar, switch it off and on again, then try again.",
        "unreadable": "Could not read Tailscale’s status on this Mac. Run `tailscale status` in a terminal to see what it says, then try again."]
    public static let candidates = ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/bin/tailscale"]
    private let runner: any BackendRemoteServeCommandExecuting
    private let environment: [String: String]
    private let loginPath: @Sendable () async -> String
    private let clock: @Sendable () -> Double
    private var lookedUp = false, binary: String?
    private var cached: (at: Double, value: NativeRPCValue)?
    private var inFlight: Task<NativeRPCValue, Never>?
    public init(runner: any BackendRemoteServeCommandExecuting = BackendRemoteServeCommand(), environment: [String: String],
                loginPath: @escaping @Sendable () async -> String,
                clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.runner = runner; self.environment = environment; self.loginPath = loginPath; self.clock = clock
    }
    public func resetBinaryCache() { lookedUp = false; binary = nil }
    public func find(force: Bool = false) async -> String? {
        if !force && lookedUp { return binary }
        var env = environment; env["PATH"] = await loginPath()
        let result = await runner.run(executable: "/usr/bin/which", arguments: ["tailscale"], environment: env,
            timeoutMilliseconds: 5000, maximumBytes: 1024 * 1024, stopWhen: nil)
        let found = result.stdout.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        if result.code == 0, let found, FileManager.default.isExecutableFile(atPath: found) { binary = found }
        else { binary = Self.candidates.first { FileManager.default.isExecutableFile(atPath: $0) } }
        lookedUp = true; return binary
    }
    public func execute(_ arguments: [String], timeout: Int, stopWhen: (@Sendable (String, String) -> Bool)? = nil) async -> BackendRemoteServeCommandResult {
        guard let executable = await find() else { return .init(code: -1, spawnError: "ENOENT") }
        let result = await runner.run(executable: executable, arguments: arguments, environment: environment,
            timeoutMilliseconds: timeout, maximumBytes: 8 * 1024 * 1024, stopWhen: stopWhen)
        if result.spawnError == "ENOENT" { resetBinaryCache() }
        return result
    }
    public func status(force: Bool = false) async -> NativeRPCValue {
        if !force, let cached, clock() - cached.at < 3000 { return cached.value }
        if let inFlight { return await inFlight.value }
        let task = Task { [self] in
            let result = await execute(["status", "--json"], timeout: 5000)
            return Self.status(result, binary: binary ?? "")
        }
        inFlight = task
        let value = await task.value; cached = (clock(), value); inFlight = nil; return value
    }
    public static func isAddress(_ value: String) -> Bool {
        // Node's isIPv4 (tailnet.ts:235): exactly four plain decimal octets, no leading zeros, each <= 255.
        let pieces = value.unicodeScalars.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4 else { return false }
        var parts: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.count <= 3, piece.allSatisfy({ $0.value >= 48 && $0.value <= 57 }),
                  piece.count == 1 || piece.first!.value != 48, let n = Int(String(String.UnicodeScalarView(piece))), n <= 255 else { return false }
            parts.append(n)
        }
        return parts[0] == 100 && (64...127).contains(parts[1])
    }
    public static func isAddress6(_ value: String) -> Bool {
        var address = in6_addr()
        guard !value.contains("%"), value.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return false }
        return withUnsafeBytes(of: &address) { $0.prefix(6).elementsEqual([0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]) }
    }
    public static func notReady(_ state: String, detail: String? = nil) -> NativeRPCValue {
        var fields: [NativeRPCValue.Field] = [.init("ready", .bool(false)), .init("state", .string(state)), .init("reason", .string(reasons[state] ?? reasons["unreadable"]!))]
        if let trimmed = detail?.remoteServeTrimmed, !trimmed.isEmpty { fields.append(.init("detail", .string(trimmed))) }
        return .object(fields)
    }
    public static func parseStatus(_ raw: NativeRPCValue, binary: String) -> NativeRPCValue {
        guard raw.fields != nil else { return notReady("unreadable", detail: "Tailscale returned something that was not status JSON.") }
        let backend = raw["BackendState"].string ?? ""
        let states = ["Running": "ready", "NeedsLogin": "logged-out", "NeedsMachineAuth": "needs-approval", "Stopped": "stopped", "Starting": "starting", "NoState": "starting"]
        guard let mapped = states[backend] else { return notReady("unreadable", detail: "Tailscale reported backend state \(backend.isEmpty ? "(none)" : backend).") }
        guard mapped == "ready" else { return notReady(mapped) }
        let node = raw["Self"], tailnet = raw["CurrentTailnet"]
        let ips = (node["TailscaleIPs"].elements ?? raw["TailscaleIPs"].elements ?? []).compactMap(\.string)
        guard let address = ips.first(where: isAddress) else { return notReady("no-address") }
        let fqdn = node["DNSName"].string ?? "", dns = fqdn.hasSuffix(".") ? String(fqdn.dropLast()) : fqdn
        let magic = !dns.isEmpty && tailnet["MagicDNSEnabled"].bool != false
        let suffix = raw["MagicDNSSuffix"].string.flatMap { $0.isEmpty ? nil : $0 } ?? tailnet["MagicDNSSuffix"].string ?? ""
        return .object([.init("ready", .bool(true)), .init("address", .string(address)), .init("address6", ips.first(where: isAddress6).map(NativeRPCValue.string) ?? .null),
            .init("dnsName", .string(magic ? dns : "")), .init("hostName", .string(node["HostName"].string ?? dns.components(separatedBy: ".")[0])),
            .init("tailnetName", .string(tailnet["Name"].string ?? suffix)), .init("magicDnsSuffix", .string(suffix)), .init("magicDns", .bool(magic)),
            .init("certsAvailable", .bool(!(raw["CertDomains"].elements ?? []).isEmpty)), .init("binary", .string(binary))])
    }
    public static func redactSecrets(_ text: String) -> String {
        text.replacingOccurrences(of: #"("AuthURL"\s*:\s*")[^"]+"#, with: "$1[redacted]", options: .regularExpression)
            .replacingOccurrences(of: #"https://login\.tailscale\.com/\S+"#, with: "https://login.tailscale.com/[redacted]", options: .regularExpression)
    }
    public static func status(_ result: BackendRemoteServeCommandResult, binary: String = "") -> NativeRPCValue {
        if result.spawnError == "ENOENT" { return notReady("not-installed") }
        let text = result.stdout.remoteServeTrimmed
        if text.isEmpty {
            let said = result.stderr.lowercased()
            return notReady(said.contains("failed to connect") || said.contains("is tailscale running") ? "not-running" : "unreadable", detail: result.stderr)
        }
        do { return parseStatus(try NativeRPCValue.parseJSON(Data(text.utf8), maximumBytes: 8 * 1024 * 1024), binary: binary) }
        catch { return notReady("unreadable", detail: result.stderr.isEmpty ? redactSecrets(String(text.prefix(200))) : result.stderr) }
    }
    public static func directPlan(_ status: NativeRPCValue, port: Int = 8443) -> NativeRPCValue {
        guard status["ready"].bool == true else { return .object([.init("ok", .bool(false)), .init("reason", status["reason"])]) }
        let dns = status["dnsName"].string ?? "", address = status["address"].string ?? ""
        guard status["magicDns"].bool == true, !dns.isEmpty else {
            return .object([.init("ok", .bool(false)), .init("reason", .string("MagicDNS is off for this tailnet, so this Mac has no name a phone can trust a certificate for. Turn MagicDNS on in the Tailscale admin console, then try again."))])
        }
        var hosts = [dns, "\(dns):\(port)", "\(address):\(port)"]
        if let address6 = status["address6"].string { hosts.append("[\(address6)]:\(port)") }
        return .object([.init("ok", .bool(true)), .init("hosts", .array(hosts.map(NativeRPCValue.string))),
                        .init("url", .string("https://\(dns):\(port)/")), .init("address", .string(address))])
    }
    public static func certificateResult(dns: String, certPath: String, keyPath: String, result: BackendRemoteServeCommandResult) -> NativeRPCValue {
        func failed(_ reason: String, _ message: String, detail: String? = nil) -> NativeRPCValue {
            var fields: [NativeRPCValue.Field] = [.init("ok", .bool(false)), .init("reason", .string(reason)), .init("message", .string(message))]
            if let detail, !detail.isEmpty { fields.append(.init("detail", .string(detail))) }; return .object(fields)
        }
        if result.spawnError == "ENOENT" { return failed("not-installed", reasons["not-installed"]!) }
        if result.code == 0 { return .object([.init("ok", .bool(true)), .init("certPath", .string(certPath)), .init("keyPath", .string(keyPath))]) }
        let said = (result.stdout + "\n" + result.stderr).lowercased()
        let detail = result.stderr.remoteServeTrimmed.isEmpty ? result.stdout.remoteServeTrimmed : result.stderr.remoteServeTrimmed
        if ["does not support getting tls certs", "https must be enabled", "https is not enabled", "certificate not available"].contains(where: said.contains) {
            return failed("https-disabled", "Tailscale HTTPS certificates are turned off for this tailnet, so \(dns) cannot get one. Open https://login.tailscale.com/admin/dns, turn on HTTPS Certificates, then try again. Until then your phone can only reach the plain 100.x address, which browsers never treat as secure.", detail: detail)
        }
        if said.contains("failed to connect") || said.contains("is tailscale running") { return failed("not-running", reasons["not-running"]!, detail: detail) }
        if result.code == -1 { return failed("failed", "Tailscale did not finish issuing a certificate for \(dns) within two minutes. Check that https://login.tailscale.com/admin/dns shows HTTPS Certificates on, then try again.", detail: detail) }
        return failed("failed", "Tailscale could not issue a certificate for \(dns). Run `tailscale cert \(dns)` in a terminal to see the full answer, then try again.", detail: detail)
    }
    public func ensureCertificate(dns: String, directory: URL) async -> NativeRPCValue {
        guard dns.range(of: #"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            return .object([.init("ok", .bool(false)), .init("reason", .string("bad-name")), .init("message", .string("“\(dns)” is not a MagicDNS name, so no certificate can be requested for it. Expected something like your-mac.tailnet-name.ts.net, which the tailnet status reports."))])
        }
        let cert = directory.appendingPathComponent(dns + ".crt").path, key = directory.appendingPathComponent(dns + ".key").path
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            return .object([.init("ok", .bool(false)), .init("reason", .string("failed")), .init("message", .string("Could not create \(directory.path) to keep the certificate in. Check that folder’s permissions, then try again.")), .init("detail", .string(String(describing: error)))])
        }
        return Self.certificateResult(dns: dns, certPath: cert, keyPath: key,
            result: await execute(["cert", "--min-validity", "168h", "--cert-file", cert, "--key-file", key, dns], timeout: 120_000))
    }
    public func registerChannels(_ registry: NativeChannelRegistry, ownerID: String, certificateDirectory: URL,
                                 authorize: @escaping @Sendable (NativeRPCContext) throws -> Void) async throws {
        try await registry.register("tailnet:status", ownerID: ownerID, policy: authorize) { [self] _, args in await status(force: args.first?.bool == true) }
        try await registry.register("tailnet:cert", ownerID: ownerID, policy: authorize) { [self] _, args in await ensureCertificate(dns: args.first?.string ?? "", directory: certificateDirectory) }
    }
}
