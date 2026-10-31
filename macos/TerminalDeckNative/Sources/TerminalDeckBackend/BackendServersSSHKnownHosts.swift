import Foundation
import TerminalDeckNativeCore

extension BackendServersSSH {
    /// Public host keys the person's own known_hosts lists for this address.
    /// ssh-keygen -F reads only that public file; no connection is made.
    static func trustedHostKeys(home: URL, host: String, port: Int) async -> [ScannedKey] {
        let file = home.appendingPathComponent(".ssh/known_hosts").path
        guard FileManager.default.fileExists(atPath: file), !host.hasPrefix("-") else { return [] }
        let name = port == 22 ? host : "[\(host)]:\(port)"
        let lookup = BackendServersSSHProcess(executable: URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
            arguments: ["-F", name, "-f", file], environment: environment())
        defer { lookup.close() }
        do {
            try lookup.start()
            let answer = try await lookup.collect(stdin: nil, timeoutMilliseconds: 5_000, maximumOutputBytes: 65_536)
            guard answer.code == 0, !answer.truncated else { return [] }
            return answer.stdout.split(separator: "\n").compactMap { line in
                let bits = line.split(whereSeparator: \.isWhitespace)
                guard bits.count >= 3, !bits[0].hasPrefix("#"), !bits[0].hasPrefix("@"), let key = Data(base64Encoded: String(bits[2])),
                      BackendServersConnections.algorithmOf(key) == String(bits[1]) else { return nil }
                return .init(algorithm: String(bits[1]), key: key)
            }
        } catch { return [] }
    }
}
