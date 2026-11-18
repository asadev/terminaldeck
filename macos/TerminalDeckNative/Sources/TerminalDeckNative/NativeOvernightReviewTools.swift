import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    /// The new Profile edits and bookmarks use their screen's owner and the existing consent door.
    func installOvernightReviewTools() async throws {
        guard let authority else { return }
        let owner = "native-composition:review-20261118", mcp = root.mcp, joins = self.joins
        let text = NativeRPCValue.object([.init("type", .string("string"))])
        let flag = NativeRPCValue.object([.init("type", .string("boolean"))])
        func schema(_ properties: [(String, NativeRPCValue)], required: [String] = []) -> NativeRPCValue {
            .object([.init("type", .string("object")), .init("properties", .object(properties.map { .init($0.0, $0.1) })),
                     .init("required", .array(required.map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))])
        }
        let definitions: [(String, BackendMCPTier, String, NativeRPCValue)] = [
            ("profile.account", .read, "Read the account's displayed name, username and ways to sign in. No credentials.", schema([])),
            ("profile.username", .alter, "Save the username in Personal information. Requires the person's approval and uses the account's existing validation.", schema([("username", text)], required: ["username"])),
            ("profile.disconnect", .alter, "Disconnect a removable way to sign in, by its id from profile.account. Requires the person's approval; the last way cannot be removed.", schema([("way", text)], required: ["way"])),
            ("browser.bookmarks", .read, "Read a browser profile's local bookmarks and whether its bar always shows. The empty profile is the default.", schema([("profile", text)])),
            ("browser.bookmarks.change", .alter, "Add or remove a local bookmark, or change Always show the bookmarks bar. Requires the person's approval. action: add, remove or bar; profile defaults to the default profile; url/title for add, url for remove, on for bar.", schema([("action", text), ("profile", text), ("url", text), ("title", text), ("on", flag)], required: ["action"])),
        ]
        for (id, tier, description, input) in definitions {
            let tool = try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: description, inputSchema: input, tier: tier)
            try await mcp.registerTool(tool, ownerID: owner) { caller, args in
                guard caller.allowedTiers.contains(tier) else { throw NativeRPCError(code: "not-granted", message: "This caller cannot do that.") }
                _ = try await authority.resolve(caller)
                if tier != .read {
                    try await joins.prepareNative(caller, tier: tier, sentence: description, ownerMustAnswer: true)
                }
                return .value(try await NativeOvernightReviewToolActions.perform(id, args))
            }
        }
        let ids = Set(definitions.map(\.0))
        let registered = await mcp.registrations().filter { ids.contains($0.0.id) }
        let metadata = registered.map { BackendDeckCoreCatalogueMetadata(tool: $0.0, title: $0.0.description, index: $0.0.description) }
        let policies = zip(metadata, registered).map { joins.mcpPolicy($0.0, handler: $0.1.1) }
        try joins.replaceContributions(owner: owner, [try .init(metadata: metadata, policies: policies)], policiesWrapped: true)
    }
}

@MainActor
private enum NativeOvernightReviewToolActions {
    static func perform(_ id: String, _ args: NativeRPCValue) async throws -> NativeRPCValue {
        if id.hasPrefix("profile.") {
            let model = NativeCloudAccount.shared
            guard let profile = model.accountProfile else { throw NativeRPCError(code: "unavailable", message: "The account's profile has not been read yet.") }
            if id == "profile.username" {
                guard profile.usernameCanChange else { throw NativeRPCError(code: "refused", message: "The account does not allow this username to change.") }
                if let problem = await model.saveProfileUsername(try args["username"].requireString("username", nonempty: true)) { throw NativeRPCError(code: "refused", message: problem) }
            } else if id == "profile.disconnect" {
                let way = try args["way"].requireString("way", nonempty: true)
                guard profile.ways.count > 1, profile.ways.contains(where: { $0.id == way && $0.canRemove != false }) else {
                    throw NativeRPCError(code: "refused", message: "That way to sign in cannot be disconnected.")
                }
                if let problem = await model.removeSignInWay(way) { throw NativeRPCError(code: "refused", message: problem) }
            }
            guard let current = model.accountProfile else { return .null }
            return .object([.init("name", current.name.map(NativeRPCValue.string) ?? .null),
                .init("username", current.username.map(NativeRPCValue.string) ?? .null), .init("usernameCanChange", .bool(current.usernameCanChange)),
                .init("ways", .array(current.ways.map { way in .object([.init("id", way.id.map(NativeRPCValue.string) ?? .null),
                    .init("provider", .string(way.provider)), .init("canRemove", .bool(current.ways.count > 1 && way.id != nil && way.canRemove != false))]) }))])
        }
        let store = NativeBrowserBookmarksStore.shared, profile = args["profile"].string ?? ""
        if id == "browser.bookmarks.change" {
            switch args["action"].string {
            case "bar":
                guard let on = args["on"].bool else { throw NativeRPCError.invalidArguments("Choose on or off.") }
                store.alwaysShowBar = on
            case "add", "remove":
                let raw = try args["url"].requireString("url", nonempty: true)
                guard let clean = BrowserHistory.visitable(raw), let url = URL(string: clean) else { throw NativeRPCError.invalidArguments("Choose a web address.") }
                if args["action"].string == "remove" {
                    if let mark = store.list(profile: profile).first(where: { $0.url == clean }) { store.remove(mark) }
                } else if !store.contains(profile: profile, url: url) {
                    guard store.toggle(profile: profile, url: url, title: args["title"].string ?? "", favicon: nil) == true else {
                        throw NativeRPCError(code: "refused", message: "That bookmark could not be added. The profile may have reached its bookmark limit.")
                    }
                }
            default: throw NativeRPCError.invalidArguments("Choose add, remove or bar.")
            }
        }
        return .object([.init("alwaysShowBar", .bool(store.alwaysShowBar)), .init("bookmarks", .array(store.list(profile: profile).map {
            .object([.init("url", .string($0.url)), .init("title", .string($0.title)), .init("addedAt", .number($0.addedAt))])
        }))])
    }
}
