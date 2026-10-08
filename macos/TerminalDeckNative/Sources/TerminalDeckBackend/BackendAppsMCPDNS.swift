import Foundation
import Darwin
import TerminalDeckNativeCore

/// System DNS, on demand. No HTTP resolver, polling or new service process.
public enum BackendAppsMCPDNS {
    /// Saved server endpoints may be numeric. Custom app domains still use
    /// the separate strict hostname validator in resolve(_:).
    public static func numericAddress(_ address: String) -> String? {
        guard !address.isEmpty, !address.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }) else { return nil }
        let value: String
        if address.hasPrefix("[") {
            guard address.hasSuffix("]"), address.count > 2 else { return nil }
            value = String(address.dropFirst().dropLast())
            guard !value.contains("["), !value.contains("]"), value.contains(":") else { return nil }
        } else {
            guard !address.contains("["), !address.contains("]") else { return nil }
            value = address
        }
        func ipv4Syntax(_ text: String) -> Bool {
            let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
            return pieces.count == 4 && pieces.allSatisfy { part in
                !part.isEmpty && part.utf8.count <= 3 && part.utf8.allSatisfy { (48...57).contains($0) }
                    && (part.count == 1 || part.first != "0") && Int(part).map { $0 <= 255 } == true
            }
        }
        if value.contains(":") {
            guard value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) || $0 == 58 || $0 == 46 }) else { return nil }
            if value.contains("."), let tail = value.split(separator: ":").last, !ipv4Syntax(String(tail)) { return nil }
        } else if !ipv4Syntax(value) { return nil }
        var ipv4 = in_addr(); var ipv6 = in6_addr()
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if inet_pton(AF_INET, value, &ipv4) == 1,
           inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(buffer.count)) != nil { return String(cString: buffer) }
        if inet_pton(AF_INET6, value, &ipv6) == 1,
           inet_ntop(AF_INET6, &ipv6, &buffer, socklen_t(buffer.count)) != nil { return String(cString: buffer) }
        return nil
    }
    public static func resolve(_ hostname: String) async throws -> [String] {
        let host = try BackendAppsCaddy.hostname(hostname)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
                var answer: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &answer) == 0, let first = answer else {
                    continuation.resume(throwing: NativeRPCError(code: "unavailable", message: "DNS could not find this address.")); return
                }
                defer { freeaddrinfo(first) }
                var results = Set<String>(); var current: UnsafeMutablePointer<addrinfo>? = first
                while let item = current {
                    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(item.pointee.ai_addr, item.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                        results.insert(String(cString: buffer))
                    }
                    current = item.pointee.ai_next
                }
                continuation.resume(returning: results.sorted())
            }
        }
    }
}
