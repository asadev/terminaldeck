import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// store-index.ts. Ed25519 is checked over transmitted bytes before parsing the catalogue.
public enum BackendAppStoreIndex {
    public static let maxBytes = 1024 * 1024, staleMilliseconds = 30.0 * 86_400_000, timeoutMilliseconds = 20_000
    public static let digestRefusal = "The download does not match the fingerprint this store has for it, so nothing was installed."
    public enum Check: Sendable {
        case accepted(index: NativeRPCValue, keyID: String, stale: String?), refused(String)
        public var wire: NativeRPCValue {
            switch self {
            case .accepted(let index, let key, let stale): return .object([.init("ok", .bool(true)), .init("index", index), .init("keyId", .string(key)), .init("stale", stale.map(NativeRPCValue.string) ?? .null)])
            case .refused(let why): return .object([.init("ok", .bool(false)), .init("why", .string(why))])
            }
        }
    }
    private typealias G = BackendSharedManifestGrammar
    private typealias M = BackendSharedStoreManifest
    public static func verify(signed: Data, signature: Data, keys: [BackendSharedStoreKey]) -> (key: String?, why: String?) {
        guard signature.count == 64 else { return (nil, "this catalogue is not signed the way ours are") }
        guard !keys.isEmpty else { return (nil, "this build carries no key to check a catalogue with") }
        for key in keys {
            guard let bytes = hex(key.hex), let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: bytes) else { continue }
            if publicKey.isValidSignature(signature, for: signed) { return (key.id, nil) }
        }
        return (nil, "this catalogue was not signed by Terminal Deck, so it was not used")
    }
    public static func artifactMatches(_ bytes: Data, expectedHex: String) -> Bool {
        guard let expected = hex(expectedHex) else { return false }
        let actual = Array(SHA256.hash(data: bytes)); var difference: UInt8 = 0
        for (a, b) in zip(actual, expected) { difference |= a ^ b }; return difference == 0
    }
    private static func hex(_ raw: String) -> Data? {
        guard raw.utf16.count == 64, raw.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else { return nil }
        let chars = Array(raw); var bytes: [UInt8] = []
        for index in stride(from: 0, to: chars.count, by: 2) { guard let n = UInt8(String(chars[index...index + 1]), radix: 16) else { return nil }; bytes.append(n) }
        return Data(bytes)
    }
    public static func parseEnvelope(_ text: String) throws -> NativeRPCValue {
        if text.utf8.count > maxBytes { try G.fail("this catalogue is larger than this app will read") }
        let raw: NativeRPCValue
        do { raw = try NativeRPCValue.parseJSON(Data(text.utf8)) } catch { try G.fail("the catalogue this app was pointed at is not valid JSON") }
        guard raw.fields != nil else { try G.fail("a catalogue must be a JSON object") }
        try G.onlyKeys("the catalogue", raw, ["v", "keyId", "alg", "sig", "signed"])
        if raw["v"] != .number(1) { try G.fail("this catalogue is written for format \(jsString(raw["v"])), and this app reads format 1") }
        if raw["alg"] != .string("ed25519") { try G.fail("this catalogue is signed with \(jsString(raw["alg"])), which this app does not check") }
        return try .object([.init("v", .number(1)), .init("keyId", .string(G.text("keyId", raw["keyId"], 40))), .init("alg", .string("ed25519")),
            .init("sig", .string(G.text("sig", raw["sig"], 200))), .init("signed", .string(G.text("signed", raw["signed"], maxBytes)))])
    }
    public static func check(_ bytes: String, keys: [BackendSharedStoreKey] = BackendSharedStoreKeys.live, highWater: Double = 0, now: Double = Date().timeIntervalSince1970 * 1000) -> Check {
        do {
            let envelope = try parseEnvelope(bytes)
            let signed = nodeBase64(envelope["signed"].string ?? ""), signature = nodeBase64(envelope["sig"].string ?? "")
            if signed.isEmpty { return .refused("this catalogue carries no list at all") }
            if signed.count > maxBytes { return .refused("this catalogue is larger than this app will read") }
            let verified = verify(signed: signed, signature: signature, keys: keys)
            guard let key = verified.key else { return .refused(verified.why ?? "this catalogue could not be read") }
            let index = try parseDocument(signed)
            if (index["serial"].number ?? 0) < highWater { return .refused("this is an older list than one this machine has already seen, so it was not used. An old list can put back something that was withdrawn.") }
            return .accepted(index: index, keyID: key, stale: staleness(index, now: now))
        } catch let error as BackendSharedManifestRefusal { return .refused(error.why) }
        catch { return .refused("this catalogue could not be read") }
    }
    public static func parseDocument(_ bytes: Data) throws -> NativeRPCValue {
        let raw: NativeRPCValue
        do { raw = try NativeRPCValue.parseJSON(bytes) } catch { try G.fail("the signed part of this catalogue is not valid JSON") }
        if raw.fields == nil { try G.fail("a catalogue must be a JSON object") }
        try G.onlyKeys("the catalogue", raw, ["v", "serial", "issuedAt", "expiresAt", "generator", "truncated", "items", "revoked"])
        if raw["v"] != .number(1) { try G.fail("this catalogue is written for format \(jsString(raw["v"])), and this app reads format 1") }
        guard let truncated = raw["truncated"].bool else { try G.fail("truncated must be true or false") }
        guard let rawItems = raw["items"].elements else { try G.fail("items must be a list") }
        guard let rawRevoked = raw["revoked"].elements else { try G.fail("revoked must be a list") }
        let items = try rawItems.enumerated().map { try row("item \($0.offset + 1)", $0.element) }
        var seen = Set<String>()
        for item in items { let id = item["id"].string!; if !seen.insert(id).inserted { try G.fail("this catalogue lists \(id) twice") } }
        let revoked = try rawRevoked.enumerated().map { entry -> NativeRPCValue in
            let name = "revoked[\(entry.offset)]", value = entry.element
            if value.fields == nil { try G.fail("\(name) must be an object") }; try G.onlyKeys(name, value, ["id", "version", "reason"])
            return try .object([.init("id", .string(G.text(name + ".id", value["id"], 82))), .init("version", .string(G.text(name + ".version", value["version"], 20))), .init("reason", .string(G.text(name + ".reason", value["reason"], 200)))])
        }
        return try .object([.init("v", .number(1)), .init("serial", .number(whole("serial", raw["serial"], 9_007_199_254_740_991))),
            .init("issuedAt", .string(stamp("issuedAt", raw["issuedAt"]))), .init("expiresAt", optionalStamp("expiresAt", raw["expiresAt"])),
            .init("generator", .string(G.text("generator", raw["generator"], 120))), .init("truncated", .bool(truncated)), .init("items", .array(items)), .init("revoked", .array(revoked))])
    }
    private static func row(_ name: String, _ raw: NativeRPCValue) throws -> NativeRPCValue {
        if raw.fields == nil { try G.fail("\(name) must be an object") }
        try G.onlyKeys(name, raw, ["id", "publisher", "listedBy", "kind", "name", "summary", "version", "licence", "category", "tags", "agents", "platforms", "tier", "needs", "cost", "costNote", "delivery", "source", "artifact", "install", "icon", "ai", "network", "repoStats", "publishedAt", "updatedAt"])
        let publisher = try G.text(name + ".publisher", raw["publisher"], 40)
        if !matches(publisher, G.safeID) { try G.fail("\(name).publisher must be lower-case letters, digits and hyphens") }
        let id = try G.text(name + ".id", raw["id"], 82), parts = id.components(separatedBy: "/")
        if parts.count != 2 || parts[0] != publisher || !matches(parts.last ?? "", G.safeID) { try G.fail("\(name).id must be written \(publisher)/<id>, so a row can never be filed under somebody else") }
        let kind = try G.oneOf(name + ".kind", raw["kind"], M.kinds), agents = try stringList(name + ".agents", raw["agents"], M.agents)
        if agents.isEmpty { try G.fail("\(name).agents must name at least one agent") }
        let tier = try whole(name + ".tier", raw["tier"], 3), floor = M.kindTierFloor[kind] ?? 1
        if tier < 1 { try G.fail("\(name).tier must be 1, 2 or 3") }
        if tier < Double(floor) { try G.fail("\(name) calls itself tier \(Int(tier)), and a \(kind) can never be less than \(floor)") }
        let cost = try G.oneOf(name + ".cost", raw["cost"], M.costs), costNote = try optionalText(name + ".costNote", raw["costNote"], 160)
        if cost != "free" && costNote == .null { try G.fail("\(name) costs something and does not say what, and a price has to be on the row before the button") }
        let delivery = try G.oneOf(name + ".delivery", raw["delivery"], M.deliveries), source = raw["source"]
        if source.fields == nil { try G.fail("\(name).source must be an object") }; try G.onlyKeys(name + ".source", source, ["repo", "commit", "path", "host"])
        let commit = try G.text(name + ".source.commit", source["commit"], 40)
        if !matches(commit, "^[0-9a-f]{40}$") { try G.fail("\(name).source.commit must be a 40-character commit, never a tag — a tag moves and the bytes must not") }
        let parsedSource = try NativeRPCValue.object([.init("repo", .string(G.text(name + ".source.repo", source["repo"], 300))), .init("commit", .string(commit)),
            .init("path", .string(G.text(name + ".source.path", source["path"], 200))), .init("host", .string(G.text(name + ".source.host", source["host"], 100)))])
        var artifact = NativeRPCValue.null
        if !raw["artifact"].isNullish {
            let value = raw["artifact"]; if value.fields == nil { try G.fail("\(name).artifact must be an object") }
            try G.onlyKeys(name + ".artifact", value, ["url", "sha256", "bytes", "files", "unpacked"])
            let digest = try G.text(name + ".artifact.sha256", value["sha256"], 64)
            if !matches(digest, "^[0-9a-f]{64}$") { try G.fail("\(name).artifact.sha256 must be 64 hex characters") }
            artifact = try .object([.init("url", .string(G.text(name + ".artifact.url", value["url"], 400))), .init("sha256", .string(digest)),
                .init("bytes", .number(whole(name + ".artifact.bytes", value["bytes"], 512 * 1024 * 1024))), .init("files", .number(whole(name + ".artifact.files", value["files"], 100_000))), .init("unpacked", .number(whole(name + ".artifact.unpacked", value["unpacked"], 1024 * 1024 * 1024)))])
        }
        var install = NativeRPCValue.null
        if !raw["install"].isNullish {
            let parsed = M.readInstallBlock(kind: kind, value: raw["install"], agents: agents)
            guard let value = parsed.value else { try G.fail("\(name).install: \(parsed.why ?? "this catalogue could not be read")") }; install = value
        }
        var network: [String] = []
        if !raw["network"].isNullish {
            guard let entries = raw["network"].elements else { try G.fail("\(name).network must be a list") }
            if entries.count > 40 { try G.fail("\(name).network may name at most 40 hosts") }
            for (index, value) in entries.enumerated() { let host = try G.text("\(name).network[\(index)]", value, 120).lowercased(); if !network.contains(host) { network.append(host) } }
        }
        let icon = try optionalText(name + ".icon", raw["icon"], 40)
        if let value = icon.string, !matches(value, "^[a-z0-9-]+$") { try G.fail("\(name).icon must name one of this app's own logos, never a link") }
        let ai = try optionalText(name + ".ai", raw["ai"], 300)
        if let value = ai.string {
            guard let url = URLComponents(string: value), url.scheme?.lowercased() == "https", url.host?.lowercased() == "terminaldeck.dev" else { try G.fail("\(name).ai must be an https address on terminaldeck.dev") }
        }
        var stats = NativeRPCValue.null
        if !raw["repoStats"].isNullish {
            let value = raw["repoStats"]; if value.fields == nil { try G.fail("\(name).repoStats must be an object") }
            try G.onlyKeys(name + ".repoStats", value, ["stars", "openIssues", "pushedAt", "readAt"])
            stats = try .object([.init("stars", .number(whole(name + ".repoStats.stars", value["stars"], 100_000_000))), .init("openIssues", .number(whole(name + ".repoStats.openIssues", value["openIssues"], 10_000_000))),
                .init("pushedAt", .string(stamp(name + ".repoStats.pushedAt", value["pushedAt"]))), .init("readAt", .string(stamp(name + ".repoStats.readAt", value["readAt"])))])
        }
        var tags: [String] = []
        for (index, value) in try G.list(name + ".tags", raw["tags"], 12).enumerated() {
            let tag = try G.text("\(name).tags[\(index)]", value, 24)
            if !matches(tag, M.tagPattern) { try G.fail("\(name).tags[\(index)] must be lower-case letters, digits and hyphens") }
            if !tags.contains(tag) { tags.append(tag) }
        }
        return try .object([.init("id", .string(id)), .init("publisher", .string(publisher)), .init("listedBy", .string(G.text(name + ".listedBy", raw["listedBy"], 40))),
            .init("kind", .string(kind)), .init("name", .string(G.text(name + ".name", raw["name"], 60))), .init("summary", .string(G.text(name + ".summary", raw["summary"], 120))),
            .init("version", .string(G.text(name + ".version", raw["version"], 20))), .init("licence", .string(G.oneOf(name + ".licence", raw["licence"], M.licences))),
            .init("category", .string(G.oneOf(name + ".category", raw["category"], M.categories))), .init("tags", words(tags)), .init("agents", words(agents)),
            .init("platforms", words(stringList(name + ".platforms", raw["platforms"], M.platforms))), .init("tier", .number(tier)), .init("needs", words(stringList(name + ".needs", raw["needs"], M.needs))),
            .init("cost", .string(cost)), .init("costNote", costNote), .init("delivery", .string(delivery)), .init("source", parsedSource), .init("artifact", artifact), .init("install", install),
            .init("icon", icon), .init("ai", ai), .init("network", words(network)), .init("repoStats", stats), .init("publishedAt", .string(stamp(name + ".publishedAt", raw["publishedAt"]))), .init("updatedAt", .string(stamp(name + ".updatedAt", raw["updatedAt"])))])
    }
    private static func whole(_ name: String, _ raw: NativeRPCValue, _ maximum: Double) throws -> Double {
        guard let value = raw.number, value.rounded(.towardZero) == value, value >= 0, value <= 9_007_199_254_740_991 else { try G.fail("\(name) must be a whole number") }
        if value > maximum { try G.fail("\(name) is larger than this app will read") }; return value
    }
    private static func stamp(_ name: String, _ raw: NativeRPCValue) throws -> String { let text = try G.text(name, raw, 40); if date(text) == nil { try G.fail("\(name) is not a date") }; return text }
    private static func optionalStamp(_ name: String, _ raw: NativeRPCValue) throws -> NativeRPCValue { raw.isNullish ? .null : .string(try stamp(name, raw)) }
    private static func optionalText(_ name: String, _ raw: NativeRPCValue, _ limit: Int) throws -> NativeRPCValue { raw.isNullish ? .null : .string(try G.text(name, raw, limit)) }
    private static func stringList(_ name: String, _ raw: NativeRPCValue, _ allowed: [String]) throws -> [String] {
        var result: [String] = []
        for (index, value) in try G.list(name, raw, allowed.count).enumerated() { let text = try G.oneOf("\(name)[\(index)]", value, allowed); if !result.contains(text) { result.append(text) } }
        return result
    }
    private static func matches(_ value: String, _ expression: String) -> Bool { value.range(of: expression, options: .regularExpression) != nil }
    private static func words(_ value: [String]) -> NativeRPCValue { .array(value.map(NativeRPCValue.string)) }
    private static func jsString(_ value: NativeRPCValue) -> String { value == .missing ? "undefined" : value.string ?? value.compact }
    private static func nodeBase64(_ raw: String) -> Data {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        let normalized = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        var clean = String(normalized.prefix { $0 != "=" }.filter { alphabet.contains($0) })
        if clean.count % 4 == 1 { clean.removeLast() }
        clean += String(repeating: "=", count: (4 - clean.count % 4) % 4)
        return Data(base64Encoded: clean) ?? Data()
    }
    public static func date(_ raw: String) -> Double? {
        let formatter = ISO8601DateFormatter()
        let variants: [ISO8601DateFormatter.Options] = [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime], [.withFullDate]]
        for options in variants {
            formatter.formatOptions = options
            if let date = formatter.date(from: raw) { return date.timeIntervalSince1970 * 1000 }
        }
        return nil
    }
    public static func staleness(_ index: NativeRPCValue, now: Double) -> String? {
        guard let issued = index["issuedAt"].string.flatMap(date) else { return "This list does not say when it was made." }
        if issued > now + 60_000 { return "This list is dated in the future, so its date cannot be trusted." }
        if let expires = index["expiresAt"].string.flatMap(date), expires < now { return "This list has passed the date it was good until." }
        let age = now - issued
        return age > staleMilliseconds ? "This list is \(Int(floor(age / 86_400_000))) days old." : nil
    }
    public static func revocation(_ index: NativeRPCValue, id: String, version: String) -> NativeRPCValue? {
        index["revoked"].elements?.first { $0["id"].string == id && ($0["version"].string == "*" || $0["version"].string == version) }
    }
}
