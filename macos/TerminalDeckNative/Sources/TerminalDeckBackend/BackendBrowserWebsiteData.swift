import Foundation
import TerminalDeckNativeCore

public struct BackendBrowserWebsiteProfile: Sendable {
    public let id: String
    public let name: String
    public let partition: String
    public init(id: String, name: String, partition: String) { self.id = id; self.name = name; self.partition = partition }
}

/// UI/tool results contain cookie metadata only. Raw values remain within the
/// explicitly authorized data bridge and never become a public tool result.
@MainActor
public final class BackendBrowserWebsiteData {
    public typealias Profile = @Sendable (NativeRPCContext, String?) async throws -> BackendBrowserWebsiteProfile
    public typealias Authorize = @Sendable (NativeRPCContext, String, String, String?) async throws -> Void
    private let runtime: any BackendBrowserRuntime
    private let profile: Profile
    private let authorize: Authorize
    public init(runtime: any BackendBrowserRuntime, resolveProfile: @escaping Profile, authorize: @escaping Authorize) {
        self.runtime = runtime; profile = resolveProfile; self.authorize = authorize
    }
    public func call(_ context: NativeRPCContext, action: String, profileID: String? = nil, site: String? = nil) async throws -> NativeRPCValue {
        guard ["info", "cookies", "clearcookies", "clearstorage", "clearcache"].contains(action) else { throw NativeRPCError.invalidArguments("Unknown browser data action.") }
        let selected = try await profile(context, profileID)
        let normalizedSite = try normalize(site)
        try await authorize(context, action, selected.id, normalizedSite)
        try Task.checkCancellation()
        var args = NativeRPCValue.object([.init("partition", .string(selected.partition))])
        switch action {
        case "clearcache": _ = try await runtime.dataCommand("browser-data:clear-cache", arguments: args); return .object([.init("cleared", .bool(true))])
        case "clearstorage":
            if normalizedSite != nil { throw NativeRPCError(code: "webkit-unavailable", message: "WebKit's public data records do not identify exact scheme/host/port stores. No site data was removed. Clear the whole chosen profile, or use the site's controls.") }
            args = args.setting("options", .object([]))
            _ = try await runtime.dataCommand("browser-data:clear-storage", arguments: args)
            return .object([.init("origins", .array([]))])
        default: break
        }
        let raw = try await runtime.dataCommand("browser-data:cookies:get", arguments: args.setting("filter", .object([])))
        let cookies = try raw.requireArray("WebKit cookies")
        if action == "clearcookies" {
            var removed = 0
            for cookie in cookies where matches(cookie["domain"].string ?? "", normalizedSite) {
                let domain = cookie["domain"].string ?? ""
                let bare = domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                guard !bare.isEmpty else { throw NativeRPCError(code: "webkit-cookie", message: "A cookie has no valid removal domain.") }
                let scheme = cookie["secure"].bool == true ? "https" : "http"
                var components = URLComponents(); components.scheme = scheme; components.host = bare
                components.path = cookie["path"].string ?? "/"
                guard let url = components.url else { throw NativeRPCError(code: "webkit-cookie", message: "The cookie's removal URL is invalid.") }
                _ = try await runtime.dataCommand("browser-data:cookies:remove", arguments: args
                    .setting("url", .string(url.absoluteString)).setting("name", cookie["name"]))
                removed += 1
            }
            return .object([.init("removed", .number(Double(removed)))])
        }
        var domains: [String: [NativeRPCValue]] = [:]
        for cookie in cookies {
            let domain = cookie["domain"].string ?? ""
            guard matches(domain, normalizedSite) else { continue }
            domains[domain, default: []].append(.object([.init("name", cookie["name"]), .init("domain", .string(domain)),
                .init("path", cookie["path"]), .init("secure", cookie["secure"]), .init("httpOnly", cookie["httpOnly"]),
                .init("session", cookie["session"]), .init("expiresAt", cookie["expirationDate"].isNullish ? .null : cookie["expirationDate"]),
                .init("valueBytes", .number(Double(cookie["value"].string?.utf8.count ?? 0)))]))
        }
        let grouped = domains.sorted { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }.map { domain, rows in
            NativeRPCValue.object([.init("domain", .string(domain)), .init("cookies", .array(rows.sorted { ($0["name"].string ?? "") < ($1["name"].string ?? "") })),
                .init("persistent", .number(Double(rows.filter { $0["session"].bool != true }.count)))])
        }
        if action == "cookies" { return .array(grouped) }
        return .object([.init("profileId", .string(selected.id)), .init("profile", .string(selected.name)), .init("partition", .string(selected.partition)),
            .init("persistent", .bool(selected.partition.hasPrefix("persist:"))), .init("storagePath", .null), .init("storageExists", .null),
            .init("cookieCount", .number(Double(cookies.count))), .init("domainCount", .number(Double(Set(cookies.compactMap { $0["domain"].string }).count))),
            .init("cacheBytes", .null), .init("limitation", .string("WebKit does not expose cache byte counts or private on-disk paths."))])
    }
    private func normalize(_ site: String?) throws -> String? {
        guard let site else { return nil }
        let text = site.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw NativeRPCError.invalidArguments("An empty site is not permission to clear every site. Omit site for all.") }
        let raw = text.hasPrefix(".") ? String(text.dropFirst()) : text
        guard let url = URL(string: raw.contains("://") ? raw : "https://" + raw), let host = url.host,
              ["http", "https"].contains(url.scheme ?? ""), url.user == nil, url.password == nil else { throw NativeRPCError.invalidArguments("site must name a valid web host.") }
        return host.lowercased()
    }
    private func matches(_ domain: String, _ site: String?) -> Bool {
        guard let site else { return true }
        let bare = domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return bare == site || bare.hasSuffix("." + site)
    }
    public func registerChannels(_ registry: NativeChannelRegistry, ownerID: String = "native-safari-data") async throws {
        let channels = ["browser-session:info": "info", "browser-session:cookies": "cookies", "browser-session:clear-cookies": "clearcookies",
                        "browser-session:clear-storage": "clearstorage", "browser-session:clear-cache": "clearcache"]
        for (channel, action) in channels {
            try await registry.register(channel, ownerID: ownerID) { [self] context, args in
                let clearsSite = action == "clearcookies" || action == "clearstorage"
                let first = context.argument(0, in: args), second = context.argument(1, in: args)
                if clearsSite, !first.isNullish, first.string == nil { throw NativeRPCError.invalidArguments("site must be text or omitted") }
                return try await call(context, action: action, profileID: (clearsSite ? second : first).string, site: clearsSite ? first.string : nil)
            }
        }
    }
    public func registerTools(_ server: BackendNativeMCPServer, context: @escaping BackendBrowserFactories.MCPContext) async throws {
        let schema = try NativeRPCValue.parseJSON(Data(#"{"type":"object","properties":{"action":{"type":"string","enum":["info","cookies","clearcookies","clearstorage","clearcache"]},"profile":{"type":"string"},"site":{"type":"string"}},"additionalProperties":false}"#.utf8))
        let tool = try BackendMCPTool(id: "browser.data", wireName: "browser_data", description: "Cookie names, flags, expiry and sizes by profile, never values. Clears require exact profile approval. WebKit cache sizes and private paths are unknown.", inputSchema: schema, tier: .read)
        try await server.registerTool(tool) { [self] caller, args in
          do {
            let action = args["action"].string ?? "info"
            let rpc = try await context(caller), selected = try await profile(rpc, args["profile"].string)
            let value = try await call(rpc, action: action, profileID: selected.id, site: args["site"].string)
            if action == "info" {
                return .value(.object([.init("profile", value["profile"]), .init("cookies", value["cookieCount"]), .init("sites", value["domainCount"]),
                    .init("cacheBytes", .null), .init("keptOnDisk", value["persistent"]), .init("folder", .null), .init("limitation", value["limitation"])]))
            }
            if action == "cookies" {
                let sites = (value.elements ?? []).map { group in
                    group.setting("site", group["domain"]).removing("domain").setting("cookies", .array((group["cookies"].elements ?? []).map { $0.removing("domain") }))
                }
                return .value(.object([.init("profile", .string(selected.name)), .init("sites", .array(sites))]))
            }
            if action == "clearstorage" { return .value(.object([.init("profile", .string(selected.name)), .init("site", args["site"].string.map(NativeRPCValue.string) ?? .string("every site")), .init("cleared", .string("everything"))])) }
            return .value(value.setting("profile", .string(selected.name)).setting("site", args["site"].string.map(NativeRPCValue.string) ?? .string("every site")))
          } catch is CancellationError { throw CancellationError() }
          catch { return .failure(NativeRPCError.wrapping(error).message) }
        }
    }
}
