import Foundation
import TerminalDeckNativeCore

public protocol BackendDeckToolsAppToolsStoreService: Sendable {
    /// {view:{tools:[StoreEntry...]},orphans:[id...]}, verified by store owner.
    func list(_ caller: BackendMCPCallContext) async throws -> NativeRPCValue
    func install(_ id: String, caller: BackendMCPCallContext) async throws -> NativeRPCValue
    func remove(_ id: String, caller: BackendMCPCallContext) async throws -> NativeRPCValue
}
public struct BackendDeckToolsAppNativeToolsStoreAdapter: BackendDeckToolsAppToolsStoreService, Sendable {
    private let recipes: BackendBrowserRecipes, access: BackendDeckToolsAppAccess
    private let removeOrphan: @Sendable (NativeRPCContext, String) async throws -> NativeRPCValue
    public init(recipes: BackendBrowserRecipes, access: BackendDeckToolsAppAccess, removeOrphan: @escaping @Sendable (NativeRPCContext, String) async throws -> NativeRPCValue) { self.recipes = recipes; self.access = access; self.removeOrphan = removeOrphan }
    public func list(_ caller: BackendMCPCallContext) async throws -> NativeRPCValue { try await recipes.list(access.rpc(caller)) }
    public func install(_ id: String, caller: BackendMCPCallContext) async throws -> NativeRPCValue { try await recipes.install(access.rpc(caller), id: id) }
    public func remove(_ id: String, caller: BackendMCPCallContext) async throws -> NativeRPCValue {
        let rpc = try await access.rpc(caller), list = try await recipes.list(rpc)
        if list["orphans"].elements?.contains(.string(id)) == true { return try await removeOrphan(rpc, id) }
        return try await recipes.remove(rpc, id: id)
    }
}
public enum BackendDeckToolsAppToolsStore {
    private typealias K = BackendDeckToolsAppKit
    private static func known(_ id: String, list: NativeRPCValue) -> Bool { list["view"]["tools"].elements?.contains { $0["id"].string == id } == true || list["orphans"].elements?.contains(.string(id)) == true }
    public static func definitions(service: any BackendDeckToolsAppToolsStoreService, access: BackendDeckToolsAppAccess) throws -> [BackendDeckToolsDefinition] {
        try K.definitions(module: "tools-store-tools", access: access, precheck: { _, context, args in
            try K.noSession(await access.caller(context), "browser.store")
            if try K.action(args) != "list" {
                let id = try K.browserStr(args, "tool"), list = try await service.list(context)
                guard known(id, list: list) else { throw K.refused("the Tools store has no tool \(id). action \"list\" names them.") }
            }
        }, consent: { _, context, args in
            let action = try K.action(args), id = args["tool"].string ?? "?", list = try await service.list(context), name = list["view"]["tools"].elements?.first { $0["id"].string == id }?["name"].string ?? id
            return (action == "list" ? .read : .alter, action == "install" ? "Install \(name) from the browser’s Tools store" : action == "remove" ? "Remove \(name) from the browser" : "List the browser’s Tools store", false)
        }, run: { _, context, args in
            let action = try K.action(args)
            if action == "list" {
                let list = try await service.list(context), rows = list["view"]["tools"].elements ?? [], orphans = list["orphans"].elements ?? []
                let tools = rows.map { row in
                    var value = K.object([("tool", row["id"]), ("name", row["name"]), ("summary", row["summary"]), ("state", row["state"]), ("version", row["version"]), ("installedVersion", row["installedVersion"]), ("runsOn", (row["origins"].elements ?? []).isEmpty ? .string("any page") : row["origins"]), ("reads", row["reads"]), ("sha256", row["sha256"]), ("licence", row["licence"])])
                    if row["message"].string != "" { value = value.setting("message", row["message"]) }; return value
                }
                var value = K.object([("tools", .array(tools))]); if !orphans.isEmpty { value = value.setting("withdrawnButInstalled", .array(orphans)) }
                return .init(value, K.object([("tools", K.n(tools.count)), ("installed", K.n(tools.filter { $0["state"].string == "installed" }.count))]))
            }
            let id = try K.browserStr(args, "tool"), result: NativeRPCValue
            if action == "install" { result = try await service.install(id, caller: context) } else { result = try await service.remove(id, caller: context) }
            guard result["ok"].bool == true else { throw K.refused(result["message"].string ?? "The store write was refused.") }
            var value = K.object([("tool", .string(id)), (action == "install" ? "installed" : "removed", .bool(true)), ("message", result["message"])])
            if action == "install" { value = value.setting("next", .string("browser.extract runs it on a page.")) }
            return .init(value, K.object([("tool", .string(id))]))
        })
    }
}

public protocol BackendDeckToolsAppCommunityService: Sendable {
    func view() async throws -> NativeRPCValue
    func install(_ id: String, choice: NativeRPCValue) async throws -> NativeRPCValue
    func remove(_ id: String) async throws -> NativeRPCValue
}
private actor BackendDeckToolsAppSeenCommunity {
    private var items: [NativeRPCValue] = []
    func set(_ items: [NativeRPCValue]) { self.items = items }
    func get(_ id: String) -> NativeRPCValue? { items.first { $0["id"].string == id } }
}
public enum BackendDeckToolsAppCommunity {
    private typealias K = BackendDeckToolsAppKit
    public static func tierWords(_ tier: Double?) -> String {
        if tier == 1 { return "Text only — nothing runs" }
        if tier == 2 { return "Ships scripts the agent may run" }
        return "Runs a program on this machine"
    }
    public static func row(_ item: NativeRPCValue) -> NativeRPCValue {
        let publisher = item["publisher"].string ?? ""
        var value = K.object([("item", item["id"]), ("name", item["name"]), ("kind", item["kind"]), ("publisher", publisher.isEmpty ? item["handle"] : item["publisher"]), ("summary", item["summary"]), ("version", item["version"]), ("state", item["state"]), ("whatItRuns", .string(tierWords(item["tier"].number))), ("agents", item["agents"]), ("needs", item["needs"]), ("reaches", item["network"]), ("writes", item["lands"]), ("cost", item["cost"]), ("licence", item["licence"]), ("repo", item["repo"])])
        for (from, to) in [("installedVersion", "installedVersion"), ("trigger", "runsWhen"), ("message", "message")] where item[from].string != "" { value = value.setting(to, item[from]) }
        for (from, to) in [("missing", "missingHere"), ("variables", "asksFor")] where !(item[from].elements ?? []).isEmpty { value = value.setting(to, item[from]) }
        return value
    }
    public static func choice(_ args: NativeRPCValue) throws -> NativeRPCValue {
        var choice = NativeRPCValue.object([])
        if args["agents"] != .missing {
            guard let agents = args["agents"].elements, agents.allSatisfy({ $0.string != nil }) else { throw K.refused("agents must be a list of agent names: claude, codex, gemini") }
            choice = choice.setting("agents", .array(agents))
        }
        if args["values"] != .missing {
            guard let values = args["values"].fields else { throw K.refused("values must be an object of the item’s inputs by key") }
            for field in values where field.value.string == nil { throw K.refused("values.\(field.key) must be text") }
            choice = choice.setting("values", .object(values))
        }
        if let folder = try K.browserOptStr(args, "folder") { choice = choice.setting("folder", .string(folder)) }
        return choice
    }
    public static func definitions(service: any BackendDeckToolsAppCommunityService, access: BackendDeckToolsAppAccess) throws -> [BackendDeckToolsDefinition] {
        let seen = BackendDeckToolsAppSeenCommunity()
        return try K.definitions(module: "community-tools", access: access, precheck: { _, context, args in
            try K.noSession(await access.caller(context), "store.community")
            let action = try K.action(args)
            if action != "list" { _ = try K.browserStr(args, "item") }
            if action == "install" { _ = try choice(args) }
        }, consent: { _, _, args in
            let action = try K.action(args), id = args["item"].string ?? "?", row = await seen.get(id), sentence: String
            let publisher = row?["publisher"].string ?? "", name = row.map { "\($0["name"].string ?? id) by \(publisher.isEmpty ? $0["handle"].string ?? "" : publisher)" } ?? id
            if action == "install" { sentence = "Install \(name) from the Store — this runs someone else's work on this Mac (\(row.map { tierWords($0["tier"].number) } ?? "what it runs is shown on its page"))" }
            else if action == "remove" { sentence = "Remove \(name) and everything its install wrote" }
            else { sentence = "List the Store’s Community shelf" }
            return (action == "list" ? .read : .alter, sentence, false)
        }, run: { _, _, args in
            let action = try K.action(args)
            if action == "list" {
                let view = try await service.view(), all = view["items"].elements ?? []
                await seen.set(all)
                let kind = try K.browserOptStr(args, "kind"), query = try K.browserOptStr(args, "query")?.lowercased()
                let items = all.filter { item in
                    guard kind == nil || item["kind"].string == kind else { return false }
                    guard let query else { return true }
                    return (item["name"].string ?? "").lowercased().contains(query) || (item["summary"].string ?? "").lowercased().contains(query) || (item["tags"].elements ?? []).contains { ($0.string ?? "").lowercased().contains(query) }
                }.map(row)
                var value = K.object([("items", .array(items)), ("from", .string(view["from"].string == "store" ? "fetched now" : "the copy kept \(view["at"].string ?? "")")), ("agentsHere", .array((view["agents"].elements ?? []).map { K.object([("agent", $0["id"]), ("name", $0["name"]), ("found", $0["found"])]) }))])
                for key in ["stale", "problem"] where view[key].string != "" { value = value.setting(key, view[key]) }
                return .init(value, K.object([("items", K.n(items.count))]))
            }
            let id = try K.browserStr(args, "item"), result: NativeRPCValue
            if action == "install" { result = try await service.install(id, choice: choice(args)) } else { result = try await service.remove(id) }
            guard result["ok"].bool == true else { throw K.refused(result["message"].string ?? "The community install was refused.") }
            return .init(K.object([("item", .string(id)), (action == "install" ? "installed" : "removed", .bool(true)), ("message", result["message"])]), K.object([("item", .string(id))]))
        })
    }
}

/// Safari worker supplies the authorized window target, real current URL and
/// driver extraction. `installed` is parsed, digest-verified raw recipe data.
/// The recipe is declarative; this seam must not execute downloaded code.
public protocol BackendDeckToolsAppExtractionService: Sendable {
    func installed() async throws -> [NativeRPCValue]
    /// Retains boundOf's session/window binding, isolated-world and secret guard.
    func origin(_ caller: BackendMCPCallContext, arguments: NativeRPCValue) async throws -> String?
    func extract(_ caller: BackendMCPCallContext, arguments: NativeRPCValue, recipe: NativeRPCValue, limit: Int?) async throws -> NativeRPCValue
}
public enum BackendDeckToolsAppExtraction {
    private typealias K = BackendDeckToolsAppKit
    public static let storePlace = "the browser's ⋯ menu, under Tools store"
    public static let maxExtractLimit = 2000
    public static func originWords(_ origins: [String]) -> String { origins.contains("*") ? "any page" : origins.joined(separator: ", ") }
    public static func allows(_ origins: [String], url: String) -> Bool {
        if origins.contains("*") { return true }
        guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""), let host = parsed.host?.lowercased() else { return false }
        return origins.contains { origin in if origin.hasPrefix("*.") { let bare = String(origin.dropFirst(2)); return host == bare || host.hasSuffix("." + bare) }; return host == origin }
    }
    public static func listInstalled(_ recipes: [NativeRPCValue]) -> [NativeRPCValue] {
        recipes.map { recipe in
            var fields = (recipe["fields"].elements ?? []).compactMap { $0["name"].string }
            if !recipe["rows"].isNullish { fields += (recipe["rows"]["fields"].elements ?? []).compactMap { $0["name"].string.map { "\($0) (per row)" } } }
            return K.object([("tool", recipe["id"]), ("name", recipe["name"]), ("reads", recipe["summary"]), ("runsOn", .string(originWords(recipe["origins"].elements?.compactMap(\.string) ?? []))), ("fields", K.strings(fields))])
        }
    }
    public static func collected(hasRows: Bool, result: NativeRPCValue) -> (onPage: Int, returned: Int) {
        if hasRows { return (Int(result["rowsOnPage"].number ?? 0), Int(result["rowsReturned"].number ?? 0)) }
        return (Int((result["counts"].fields ?? []).map { $0.value["matched"].number ?? 0 }.max() ?? 0), Int((result["counts"].fields ?? []).map { $0.value["returned"].number ?? 0 }.max() ?? 0))
    }
    public static func trustedStated(_ stated: Double?, returned: Int) -> Double? { guard let stated, stated.isFinite, stated >= 0, stated >= Double(returned) else { return nil }; return stated }
    public static func complete(_ stated: Double?, returned: Int) -> Bool? { trustedStated(stated, returned: returned).map { Double(returned) >= $0 } }
    private static func words(_ number: Double) -> String { number.rounded(.towardZero) == number ? String(format: "%.0f", number) : String(number) }
    public static func completenessNote(stated: Double?, onPage: Int, returned: Int) -> String {
        if let stated, stated >= 0, stated < Double(returned) { return "The page states \(words(stated)), which is fewer than the \(returned) that came back, so that total was not believed. Check what the recipe is reading it from." }
        if let stated, stated > Double(returned) { return "The page accounts for \(words(stated)) and \(returned) came back. This is not the whole set — raise the limit or page on before treating it as complete.\(onPage > returned ? " The limit on this call is part of it." : "")" }
        if onPage > returned { return "The page has \(onPage) and \(returned) came back, because of the limit on this call." }
        return ""
    }
    public static func withEmptiness(_ value: NativeRPCValue, produced: Int, whenNone: String) -> NativeRPCValue { value.setting("empty", .bool(produced <= 0)).setting("emptyReason", .string(produced <= 0 ? whenNone : "")) }
    public static func definitions(service: any BackendDeckToolsAppExtractionService, access: BackendDeckToolsAppAccess) throws -> [BackendDeckToolsDefinition] {
        try K.definitions(module: "store-tools", access: access, consent: { _, _, args in return (.read, args["tool"].string.map { "read the page with \($0)" } ?? "list the installed browser tools", false) }, run: { _, context, args in
            let installed = try await service.installed(), wanted = try K.browserOptStr(args, "tool"), caller = try await access.caller(context)
            let whereToInstall = caller.kind == .session ? "A person installs them from \(storePlace); nothing on this surface can install one." : "A person installs them from \(storePlace), or browser.store installs one (it asks them first)."
            guard let wanted else {
                let tools = listInstalled(installed), value = K.object([("tools", .array(tools)), ("note", .string(tools.isEmpty ? "No browser tools are installed. \(whereToInstall)" : ""))])
                return .init(withEmptiness(value, produced: tools.count, whenNone: "no browser tool is installed, so there is nothing here to run. \(whereToInstall) Say what you would have used."), K.object([("tools", K.n(tools.count)), ("empty", .bool(tools.isEmpty))]))
            }
            guard let recipe = installed.first(where: { $0["id"].string == wanted }) else {
                let names = installed.compactMap { $0["id"].string }
                throw K.refused(names.isEmpty ? "no browser tool called \(wanted) is installed, and nor is any other. \(whereToInstall)" : "no browser tool called \(wanted) is installed. These are: \(names.joined(separator: ", ")).")
            }
            let origin = try await service.origin(context, arguments: args), origins = recipe["origins"].elements?.compactMap(\.string) ?? [], name = recipe["name"].string ?? wanted
            guard let origin, allows(origins, url: origin) else { throw K.refused("\(name) only runs on \(originWords(origins)), and this page is \(origin ?? "not one this app can read an address for").") }
            let limit: Int?
            if args["limit"].isNullish { limit = nil }
            else { guard args["limit"].number != nil else { throw K.refused("limit must be a number") }; limit = try BackendDeckToolsArgs.optInt(args, "limit", maxExtractLimit, 1, maxExtractLimit) }
            let result = try await service.extract(context, arguments: args, recipe: recipe, limit: limit), counted = collected(hasRows: !recipe["rows"].isNullish, result: result), stated = result["stated"].number
            let note = completenessNote(stated: stated, onPage: counted.onPage, returned: counted.returned)
            var value = K.object([("tool", recipe["id"]), ("url", result["url"]), ("title", result["title"]), ("fields", result["fields"]), ("rows", result["rows"]), ("rowsOnPage", result["rowsOnPage"]), ("rowsReturned", result["rowsReturned"]), ("counts", result["counts"]), ("onPage", K.n(counted.onPage)), ("returned", K.n(counted.returned)), ("stated", result["stated"]), ("complete", complete(stated, returned: counted.returned).map(NativeRPCValue.bool) ?? .null), ("next", result["next"]), ("note", .string(note))])
            let url = result["url"].string ?? "", about = "\(name) ran on \(url.isEmpty ? "this page" : url) and matched nothing. That is a fact about this call, not about the page: the selectors may no longer fit the site, the page may not have finished loading what it fetches in the background, or this may be the wrong page. Look at it with browser.read before recording that there was nothing here. Single fields that did match are still in fields."
            value = withEmptiness(value, produced: counted.returned, whenNone: about)
            return .init(value, K.object([("tool", recipe["id"]), ("rows", K.n(counted.returned)), ("onPage", K.n(counted.onPage)), ("stated", result["stated"]), ("short", .bool(!note.isEmpty)), ("empty", .bool(counted.returned <= 0))]))
        })
    }
}
