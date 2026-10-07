import Foundation
import TerminalDeckNativeCore

/// Registration is explicit. No factory starts a listener or silently replaces
/// an existing handler; duplicate registration remains an integration error.
public enum BackendBrowserFactories {
    public static let nativePageChannels: [String: String] = [
        "browser:navigate": "navigate", "browser:reload": "reload", "browser:stop": "stop",
        "browser:back": "back", "browser:forward": "forward", "browser:inspect": "inspect",
        "browser:state": "state", "browser:close": "close", "browser-view:zoom": "zoom",
        "browser-view:find": "find", "browser-view:find-stop": "findstop", "browser-view:print": "print",
        "browser-view:devtools": "devtools", "browser-view:screenshot": "user-screenshot", "browser-view:frame": "frame",
        "browser-view:user-agent": "useragent", "browser-view:record": "record", "browser-view:record-clear": "recordclear",
        "browser-view:screenshot-marked": "screenshot-marked", "browser:annotate-pick": "pick",
    ]
    public static let dataChannels = ["browser-data:cookies:get", "browser-data:cookies:set", "browser-data:cookies:remove",
        "browser-data:cookies:flush", "browser-data:clear-cache", "browser-data:clear-storage", "browser-data:cache-size",
        "browser-data:storage-path", "browser-data:fetch", "browser-data:fetch-cancel", "browser-data:bind-isolated"]
    public static func registerChannels(_ registry: NativeChannelRegistry, service: BackendBrowserService,
                                        ownerID: String = "native-safari") async throws -> [NativeRPCSubscription] {
        var subscriptions: [NativeRPCSubscription] = []
        try await registry.register("browser:create", ownerID: ownerID) { context, args in
            try await service.nativeCreate(context, arguments: context.argument(0, in: args))
        }
        try await registry.register("browser:bindings", ownerID: ownerID) { context, _ in try await service.bindingsView(context) }
        try await registry.register("link:open", ownerID: ownerID) { context, args in try await service.openLink(context, arguments: context.argument(0, in: args)) }
        for (channel, operation) in nativePageChannels {
            try await registry.register(channel, ownerID: ownerID) { context, args in
                let id = try context.argument(0, in: args).requireString("tabId", nonempty: true)
                let second = context.argument(1, in: args)
                let value: NativeRPCValue
                switch operation {
                case "navigate": value = .object([.init("url", second)])
                case "zoom": value = .object([.init("factor", second)])
                case "find": value = context.argument(2, in: args).merging(.object([.init("text", second)]))
                case "findstop": value = .object([.init("keepSelection", second)])
                case "useragent": value = .object([.init("userAgent", second)])
                case "inspect": value = .object([.init("on", second)])
                case "record": value = second.fields != nil ? second : .object([.init("on", second)])
                case "screenshot-marked": value = .object([.init("png", second)])
                case "pick": value = .object([.init("x", second), .init("y", context.argument(2, in: args))])
                default: value = .object([])
                }
                return try await service.nativePage(context, id: id, operation: operation, arguments: value)
            }
        }
        try await registry.register("browser-view:reveal", ownerID: ownerID) { context, args in
            try await service.revealScreenshot(context, path: context.argument(0, in: args).requireString("path", nonempty: true))
        }
        for channel in dataChannels {
            try await registry.register(channel, ownerID: ownerID) { context, args in
                try await service.data(context, operation: channel, arguments: context.argument(0, in: args))
            }
        }
        subscriptions.append(try await registry.onSend("browser:bind", ownerID: ownerID) { context, args in
            _ = try await service.bind(context, arguments: context.argument(0, in: args))
            try await registry.publish("browser:bindings", arguments: [try await service.bindingsView(context)], ownerID: context.ownerID)
        })
        subscriptions.append(try await registry.onSend("browser:bind-new-window", ownerID: ownerID) { context, args in
            _ = try await service.bindNewWindow(context, arguments: context.argument(0, in: args))
            try await registry.publish("browser:bindings", arguments: [try await service.bindingsView(context)], ownerID: context.ownerID)
        })
        subscriptions.append(try await registry.onSend("browser:unbind", ownerID: ownerID) { context, args in
            let first = context.argument(0, in: args)
            _ = try await service.bind(context, arguments: first.fields != nil ? first : .object([.init("tabId", first)]), detach: true)
            try await registry.publish("browser:bindings", arguments: [try await service.bindingsView(context)], ownerID: context.ownerID)
        })
        subscriptions.append(try await registry.onSend("browser:drive-resume", ownerID: ownerID) { context, args in
            _ = try await service.resume(context, carryOn: context.argument(0, in: args).bool ?? false, tabID: context.argument(1, in: args).string)
        })
        try await registry.register("browser:drive-status", ownerID: ownerID) { context, _ in
            try await service.driveStatus(context)
        }
        // Extra native-only frame seam. The six public agent tools retain
        // their source names and never gain an arbitrary evaluation argument.
        try await registry.register("browser:frames", ownerID: ownerID) { context, args in
            let value = context.argument(0, in: args)
            return try await service.page(context, operation: value["action"].string ?? "frames", arguments: value, frame: true)
        }
        return subscriptions
    }
    public typealias MCPContext = @Sendable (BackendMCPCallContext) async throws -> NativeRPCContext
    public static func registerTools(_ server: BackendNativeMCPServer, service: BackendBrowserService,
                                     context: @escaping MCPContext) async throws {
        for verb in BrowserDriverVerb.allCases {
            let id = verb.rawValue.replacingOccurrences(of: "_", with: ".")
            let spec = try BackendMCPTool(id: id, wireName: verb.rawValue, description: descriptions[verb] ?? id,
                inputSchema: try schema(for: verb), tier: verb == .read || verb == .screenshot ? .read : .act)
            try await server.registerTool(spec) { caller, args in
                try await toolReply {
                    if caller.cancellation.isCancelled { throw CancellationError() }
                    let rpc = try await context(caller)
                    return try await service.drive(rpc, verb: verb, arguments: args, attended: caller.attended)
                }
            }
        }
        let page = try BackendMCPTool(id: "browser.page", wireName: "browser_page",
            description: "State and toolbar actions on an authorized browser window. Web Inspector opening reports WebKit's public API limit.",
            inputSchema: try NativeRPCValue.parseJSON(Data(pageSchema.utf8)), tier: .read)
        try await server.registerTool(page) { caller, args in
            try await toolReply {
                let rpc = try await context(caller)
                return try await service.page(rpc, operation: args["action"].string ?? "state", arguments: args)
            }
        }
        let windows = try BackendMCPTool(id: "browser.windows", wireName: "browser_windows",
            description: "List, open, attach, detach or delete browser windows. Attaching changes a session's grant and requires the person's approval.",
            inputSchema: try NativeRPCValue.parseJSON(Data(windowsSchema.utf8)), tier: .read)
        try await server.registerTool(windows) { caller, args in try await toolReply { try await service.windows(try await context(caller), arguments: args) } }
    }
    /// Domain refusals must reach the agent as their actual actionable reason,
    /// rather than the shared MCP server's generic internal-handler failure.
    public static func toolReply(_ operation: @Sendable () async throws -> NativeRPCValue) async throws -> BackendMCPToolReply {
        do { return .value(try await operation()) }
        catch is CancellationError { throw CancellationError() }
        catch let failure as NativeRPCError where failure.code == "cancelled" { throw CancellationError() }
        catch { return .failure(NativeRPCError.wrapping(error).message) }
    }
    private static let descriptions: [BrowserDriverVerb: String] = [
        .open: "Open an HTTP or HTTPS page in your own browser window, or name one of your session's B slots. New windows appear in the app's tab strip.",
        .read: "Read visible page text and actionable selectors. Password, one-time-code and file values are never readable. Use waitFor to wait for an element.",
        .step: "Click, type, select, check, press or submit after waiting for a stable visible target. Secret fields require handover. Public-site actions require an exact-origin grant.",
        .screenshot: "Save a privacy-masked PNG in the app's explicit data root. Child frames are conservatively masked. Mac paths are refused for remote callers.",
        .handover: "Give the page to the person for sign-in, passwords, payments or CAPTCHA. Agent reads and actions stop until Done or Stop; an unfinished wait returns still-waiting.",
        .close: "Delete a session's named browser window. Deleting B1 leaves B2 called B2."
    ]
    public static func schema(for verb: BrowserDriverVerb) throws -> NativeRPCValue {
        let target = #""sessionId":{"type":"string"},"window":{"type":"string"}"#
        let properties: String; let required: String
        switch verb {
        case .open: properties = #""url":{"type":"string"},"isolate":{"type":"boolean"},"newWindow":{"type":"boolean"},"# + target; required = #", "required":["url"]"#
        case .read: properties = #""selector":{"type":"string"},"waitFor":{"type":"string"},"timeoutMs":{"type":"number"},"textChars":{"type":"integer"},"# + target; required = ""
        case .step: properties = #""verb":{"type":"string","enum":["click","type","select","check","press","submit"]},"selector":{"type":"string"},"value":{"type":"string"},"key":{"type":"string","enum":["Enter","Tab","Escape","Backspace","Delete","ArrowDown","ArrowUp","ArrowLeft","ArrowRight"]},"timeoutMs":{"type":"number"},"# + target; required = #", "required":["verb","selector"]"#
        case .handover: properties = #""prompt":{"type":"string"},"# + target; required = #", "required":["prompt"]"#
        case .screenshot, .close: properties = target; required = ""
        }
        return try NativeRPCValue.parseJSON(Data(("{\"type\":\"object\",\"properties\":{" + properties + "},\"additionalProperties\":false" + required + "}").utf8))
    }
    private static let pageSchema = #"""
    {"type":"object","properties":{"action":{"type":"string","enum":["state","navigate","back","forward","reload","stop","zoom","find","findstop","print","devtools","useragent","inspect","record","recording","recordclear","screenshot","reveal"]},"sessionId":{"type":"string"},"window":{"type":"string"},"url":{"type":"string"},"factor":{"type":"number"},"text":{"type":"string"},"backwards":{"type":"boolean"},"next":{"type":"boolean"},"keepSelection":{"type":"boolean"},"userAgent":{"type":"string"},"on":{"type":"boolean"},"path":{"type":"string"}},"additionalProperties":false}
    """#
    private static let windowsSchema = #"""
    {"type":"object","properties":{"action":{"type":"string","enum":["list","open","close","attach","detach","reach","unreach"]},"window":{"type":"string"},"sessionId":{"type":"string"},"url":{"type":"string"},"machineId":{"type":"string"},"machineName":{"type":"string"},"kind":{"type":"string","enum":["device","server"]},"port":{"type":"integer"}},"additionalProperties":false}
    """#
}
