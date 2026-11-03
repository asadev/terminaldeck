import Foundation

public struct BackendSharedStoreApiChoice: Equatable, Sendable {
    public let base: String
    public let overridden: Bool
    public let ignored: String?
}

public enum BackendSharedStoreApi {
    public static let defaultBase = "https://terminaldeck.dev"
    public static let environmentKey = "TERMINALDECK_STORE_API"
    public static let indexPath = "/store/index.json"
    public static func resolve(environment: [String: String], configured: String? = nil) -> BackendSharedStoreApiChoice {
        var firstRefusal: String?
        for raw in [environment[environmentKey], configured].compactMap({ $0 }) {
            let value = BackendSharedText.trim(raw)
            if value.isEmpty { if firstRefusal == nil { firstRefusal = "it was empty" }; continue }
            guard var parts = URLComponents(string: value), let scheme = parts.scheme?.lowercased(), parts.url != nil else {
                if firstRefusal == nil { firstRefusal = "\(value) is not a web address" }; continue
            }
            if scheme != "http" && scheme != "https" {
                if firstRefusal == nil { firstRefusal = "\(value) is not http or https" }; continue
            }
            guard let host = parts.host, !host.isEmpty else {
                if firstRefusal == nil { firstRefusal = "\(value) is not a web address" }; continue
            }
            if scheme == "http" && !["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased()) {
                if firstRefusal == nil { firstRefusal = "\(value) is plain http, which is only allowed on this machine" }; continue
            }
            parts.scheme = scheme; parts.host = host.lowercased(); parts.user = nil; parts.password = nil; parts.query = nil; parts.fragment = nil
            if scheme == "http" && parts.port == 80 || scheme == "https" && parts.port == 443 { parts.port = nil }
            if parts.path.isEmpty { parts.path = "/" }
            guard var base = parts.url?.absoluteString else { continue }
            if base.hasSuffix("/") { base.removeLast() }
            return .init(base: base, overridden: true, ignored: firstRefusal)
        }
        return .init(base: defaultBase, overridden: false, ignored: firstRefusal)
    }
    public static func base(environment: [String: String], configured: String? = nil) -> String { resolve(environment: environment, configured: configured).base }
    public static func indexUrl(_ base: String) -> String { (base.hasSuffix("/") ? String(base.dropLast()) : base) + indexPath }
}

public struct BackendSharedStoreKey: Equatable, Sendable {
    public let id: String
    public let hex: String
    public let because: String
}

/// Compiled catalogue trust, shared/store-key.ts. Never reads a private key.
public enum BackendSharedStoreKeys {
    public static let developmentPhrase = "terminaldeck commons local development key"
    public static let environmentKey = "TERMINALDECK_STORE_DEV_KEY"
    public static let development = BackendSharedStoreKey(id: "td-store-dev-1", hex: "09e1704496b19517e5376f24700f45eb9f95d322993624013756c6542b7e2e80", because: "the local development key: it signs the preview catalogue the site repository serves from this machine, its private half is derivable by anyone from DEV_KEY_PHRASE, and so it must never sign a catalogue anybody else fetches and no packaged build may ever believe it. It left slot two on 2026-10-03 for exactly that reason; storeKeysFor is the only way in.")
    public static let slots: [BackendSharedStoreKey?] = [BackendSharedStoreKey(id: "td-store-1", hex: "66d8a2ecd199a16c8080c00e108911034d9b93932203ec8037d1fb4543257c34", because: "the production key: it signs the catalogue served from https://terminaldeck.dev/store. Its private half was generated on 29 August 2026, exists in exactly one place — credentials/terminaldeck-store-signing-key.json, mode 0600, on the machine that signs — and has never been in this repository, a transcript, or the site repo."), nil]
    public static var live: [BackendSharedStoreKey] { slots.compactMap { $0 } }
    public static func keys(environment: [String: String], packaged: Bool) -> [BackendSharedStoreKey] {
        !packaged && environment[environmentKey] == "1" ? live + [development] : live
    }
}
