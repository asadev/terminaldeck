import Foundation
import TerminalDeckNativeCore

/// HTTP hosts and browser origins are different boundaries. A native phone has
/// no Origin; a browser must name an exact approved origin, including its port.
enum BackendRemoteWebPolicy {
    /// The hosted web client has exactly one home, https://terminaldeck.app (2 Nov 2026). No other hosted origin is accepted.
    static let hostedOrigins: Set<String> = ["https://terminaldeck.app"]
    static func compatibleBundle(at root: URL) -> Bool {
        let index = root.appendingPathComponent("index.html"), marker = root.appendingPathComponent("build.json")
        guard (try? index.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let metadata = try? marker.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), metadata.isRegularFile == true,
              let size = metadata.fileSize, size <= 4_096, let data = try? Data(contentsOf: marker), data.count <= 4_096,
              let build = try? NativeRPCValue.parseJSON(data, maximumBytes: 4_096) else { return false }
        return build["client"].string == "terminaldeck-web" && build["bootstrap"].number == 1
    }

    static func permits(origin: String?, hosts: Set<String>) -> Bool {
        guard let origin else { return true }
        // The hosted web client: terminaldeck.app (2 Nov 2026).
        if Self.hostedOrigins.contains(origin) { return true }
        return hosts.contains { host in
            origin == (isLoopback(host) ? "http://" : "https://") + host
        }
    }

    static func localBootstrap(origin: String?, host: String) -> Bool {
        host.hasPrefix("localhost:") && origin == "http://" + host
    }

    private static func isLoopback(_ host: String) -> Bool {
        host.hasPrefix("localhost:") || host.hasPrefix("127.0.0.1:")
    }

    static func headers(hosts: Set<String>) -> String {
        let sockets = hosts.sorted().map { (isLoopback($0) ? "ws://" : "wss://") + $0 }.joined(separator: " ")
        let csp = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; media-src 'self' blob:; font-src 'self'; connect-src 'self' " + sockets + " wss://relay.terminaldeck.dev; worker-src 'self' blob:; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
        return "Content-Security-Policy: \(csp)\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\nCache-Control: no-store\r\n"
    }
}
