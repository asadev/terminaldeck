import Foundation
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

enum BackendRemoteServeHostPortTailnetFixture {
    static let binary = "/opt/homebrew/bin/tailscale"
    static let dns = "deck-mac.taild0abcd.ts.net"
    static let warning = "Warning: client version \"1.94.2-t2de4d317a\" != tailscaled server version \"1.98.9-t4fb758c39-g200941d74\"\n"
    static let running = #"{"Version":"1.98.9-t4fb758c39-g200941d74","TUN":true,"BackendState":"Running","HaveNodeKey":true,"AuthURL":"","TailscaleIPs":["100.86.107.119","fd7a:115c:a1e0::fd39:6b77"],"Self":{"ID":"nSr1hSiyP811CNTRL","HostName":"deck-mac","DNSName":"deck-mac.taild0abcd.ts.net.","OS":"macOS","TailscaleIPs":["100.86.107.119","fd7a:115c:a1e0::fd39:6b77"],"Online":true,"InNetworkMap":true},"Health":[],"MagicDNSSuffix":"taild0abcd.ts.net","CurrentTailnet":{"Name":"owner@example.com","MagicDNSSuffix":"taild0abcd.ts.net","MagicDNSEnabled":true},"CertDomains":null,"Peer":{"nodekey:example":{"DNSName":"desktop-ddgmncv.taile59277.ts.net."}}}"#
    static func raw() throws -> NativeRPCValue { try NativeRPCValue.parseJSON(Data(running.utf8)) }
    static func ran(_ raw: NativeRPCValue, warning: String = BackendRemoteServeHostPortTailnetFixture.warning, code: Int = 0) throws -> BackendRemoteServeCommandResult {
        .init(stdout: String(decoding: try raw.encodedJSON(), as: UTF8.self), stderr: warning, code: code)
    }
    static func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("td-tailnet-port-" + UUID().uuidString) }
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0.0
        func now() -> Double { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ milliseconds: Double) { lock.lock(); defer { lock.unlock() }; value += milliseconds }
    }
    actor Runner: BackendRemoteServeCommandExecuting {
        enum Mode: Equatable, Sendable { case success, promptStdout, promptStderr, timeout }
        struct Call: Sendable {
            let args: [String], timeout: Int, maximumBytes: Int
        }
        static let working = "https://desktop.tailnet.ts.net:8443/\n"
        static let notEnabled = "Serve is not enabled on your tailnet.\nTo enable, visit:\n\n\t https://login.tailscale.com/f/serve?node=nL3GN8Ypuc11CNTRL\n\n"
        let mode: Mode, clock: Clock
        var calls: [Call] = []
        var killed = 0, statusCount = 0
        init(mode: Mode = .success, clock: Clock = Clock()) { self.mode = mode; self.clock = clock }
        func snapshot() -> [Call] { calls }
        func kills() -> Int { killed }
        func statuses() -> Int { statusCount }
        func run(executable: String, arguments: [String], environment: [String: String], timeoutMilliseconds: Int,
                 maximumBytes: Int, stopWhen: (@Sendable (String, String) -> Bool)?) async -> BackendRemoteServeCommandResult {
            calls.append(.init(args: arguments, timeout: timeoutMilliseconds, maximumBytes: maximumBytes))
            // Read-only executable metadata check in production find(); this
            // fake never executes the returned path.
            if arguments == ["tailscale"] { return .init(stdout: "/usr/bin/true\n") }
            if arguments.first == "status" { statusCount += 1; await Task.yield(); return .init(stdout: BackendRemoteServeHostPortTailnetFixture.running, stderr: BackendRemoteServeHostPortTailnetFixture.warning) }
            if arguments.first == "cert" || arguments.last == "off" { return .init() }
            let stdout = mode == .promptStdout ? Self.notEnabled : mode == .success ? Self.working : ""
            let stderr = mode == .promptStderr ? Self.notEnabled : ""
            if stopWhen?(stdout, stderr) == true { killed += 1; return .init(stdout: stdout, stderr: stderr) }
            clock.advance(Double(timeoutMilliseconds)); killed += 1
            return .init(stdout: stdout, stderr: stderr, code: -1)
        }
    }
}
