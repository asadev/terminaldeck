import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Uses the app's existing caller grants, approval and action history.
enum Sidebar21MCP {
    typealias Perform = @Sendable (String, NativeRPCValue) async throws -> NativeRPCValue
    static func definitions(access: BackendDeckToolsAppAccess, perform: @escaping Perform) throws -> [BackendDeckToolsDefinition] {
        let rows: [(String, BackendMCPTier, String, String)] = [
            ("sidebar.pages.list", .read, "List More pages, their pinned state and saved order.",
             #"{"type":"object","properties":{},"additionalProperties":false}"#),
            ("sidebar.page.open", .act, "Open a More page in the main area.",
             #"{"type":"object","properties":{"page":{"type":"string"}},"required":["page"],"additionalProperties":false}"#),
            ("sidebar.page.pin", .alter, "Pin or unpin a page in the side panel.",
             #"{"type":"object","properties":{"page":{"type":"string"},"pinned":{"type":"boolean"}},"required":["page","pinned"],"additionalProperties":false}"#),
            ("sidebar.pages.reorder", .alter, "Save the order of pinned pages. Include every pinned page once.",
             #"{"type":"object","properties":{"pages":{"type":"array","items":{"type":"string"},"uniqueItems":true}},"required":["pages"],"additionalProperties":false}"#)
        ]
        return try rows.map { id, tier, title, schema in
            let wire = id.replacingOccurrences(of: ".", with: "_")
            let spec = try BackendMCPTool(id: id, wireName: wire, description: title,
                inputSchema: NativeRPCValue.parseJSON(Data(schema.utf8)), tier: tier)
            return BackendDeckToolsDefinition(spec: spec, title: title, index: title) { context, args in
                try await BackendDeckToolsSupport.reply {
                    guard (context.allowedTools.contains(id) || context.allowedTools.contains(wire)), context.allowedTiers.contains(tier) else {
                        throw NativeRPCError(code: "not-granted", message: "This caller cannot change the side panel.")
                    }
                    let caller = try await access.caller(context)
                    try BackendDeckToolsAppKit.hereOnly(caller, "Side panel pages")
                    guard !context.cancellation.isCancelled else { throw CancellationError() }
                    try await access.authorize(context, id, args, tier, title, tier != .read)
                    guard !context.cancellation.isCancelled else { throw CancellationError() }
                    let output = try await perform(id, args)
                    try await access.record(context, id, args, output)
                    return .value(output)
                }
            }
        }
    }

    @MainActor static func perform(_ id: String, args: NativeRPCValue, pins: Sidebar21Store,
                                   pages: [Sidebar21Page], open: (String) throws -> Void) throws -> NativeRPCValue {
        switch id {
        case "sidebar.pages.list": break
        case "sidebar.page.open", "sidebar.page.pin":
            let page = try args["page"].requireString("page", nonempty: true)
            guard pages.contains(where: { $0.id == page }) else { throw NativeRPCError.invalidArguments("Choose a page listed in More.") }
            if id == "sidebar.page.open" { try open(page) }
            else {
                guard let pinned = args["pinned"].bool else { throw NativeRPCError.invalidArguments("Pinned must be true or false.") }
                pins.setPinned(page, pinned: pinned, pages: pages)
            }
        case "sidebar.pages.reorder":
            guard let values = args["pages"].elements else { throw NativeRPCError.invalidArguments("Give the pinned pages in order.") }
            let order = try values.map { try $0.requireString("page", nonempty: true) }
            guard pins.reorder(order) else { throw NativeRPCError.invalidArguments("Include every pinned page exactly once.") }
        default: throw NativeRPCError.invalidArguments("Unknown side panel action.")
        }
        return .object([.init("ok", .bool(true)), .init("pages", .array(pages.map { page in
            .object([.init("id", .string(page.id)), .init("name", .string(page.title)), .init("icon", .string(page.symbol)),
                     .init("pinned", .bool(pins.isPinned(page.id))),
                     .init("order", pins.ids.firstIndex(of: page.id).map { .number(Double($0)) } ?? .null)])
        })), .init("pinnedPages", .array(pins.ids.map(NativeRPCValue.string)))])
    }

    @MainActor static func live(_ id: String, _ args: NativeRPCValue) throws -> NativeRPCValue {
        let model = AppModel.shared
        let pages = Sidebar21Pages.catalogue(model.visibleSidebar)
        let pins = Sidebar21Store.shared
        guard model.canRun, model.visibleSidebar != nil else {
            throw NativeRPCError(code: "unavailable", message: "The side panel is still starting. Please try again.")
        }
        pins.initialize(existingUser: Sidebar21Store.isUpgrade(defaults: .standard,
            dataRoot: model.engine.configuration.engineDataDirectory, state: model.visibleSidebar), pages: pages)
        return try perform(id, args: args, pins: pins, pages: pages) { model.select($0) }
    }
}
