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
            description: "One browser window's page beyond its elements. Navigation: state, navigate, back, forward, reload, stop, zoom, find, useragent. wait for: load, networkidle, url (part, glob or /regex/), selector (state visible|hidden|attached|detached|enabled), text, function (a script that turns true), download (its path), time. evaluate: run JavaScript (an expression, a function given arg, or statements with return) in the page's world or world:isolated; requires an isolated tab (open a new window with isolate: true), and is refused while a password or card field holds a value. A separate JavaScript world does not protect saved sign-ins. Scripts have page authority in the temporary store, subject to WebKit same-origin rules; never use them to read the person’s profile cookies or storage. Exposing host functions is unavailable. dialogs: answer alert/confirm/prompt (policy accept|dismiss|ask, promptText, once) and read the ones seen. console: messages and page errors (level, since, clear). requests: the page's fetch/XHR log with headers and bodies (bodies: true), har: true writes a HAR file; secrets are hidden. route: block URL patterns (all load types), mock fetch/XHR answers, extra headers, offline, clear. emulate: viewport, device, landscape, colorScheme, locale, timezone, geolocation, reset. permissions: camera/microphone ask|deny; only the person may allow them. storage: mode export|import|clear (localStorage, sessionStorage, cookies; HttpOnly cookie values are never exported). collect: rows+fields across pages (next selector) or an endless list (scroll: true). Scripts, script-waits, storage, route, requests, console, dialogs and emulation require isolated tabs, including for Hoot. A session uses these on its own B windows; Hoot also prints, records and inspects.",
            inputSchema: try NativeRPCValue.parseJSON(Data(pageSchema.utf8)), tier: .read)
        try await server.registerTool(page) { caller, args in
            try await toolReply {
                let rpc = try await context(caller)
                return try await service.page(rpc, operation: args["action"].string ?? "state", arguments: args)
            }
        }
        let windows = try BackendMCPTool(id: "browser.windows", wireName: "browser_windows",
            description: "List, open, attach, detach or delete browser windows. Attaching changes a session's grant, so it counts as a change; it runs when the calling AI's permission mode allows it.",
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
        .read: "Read the page: text and actionable elements with refs, or mode accessibility (role tree), links, tables, html, matches (all a selector finds), extract (rows + fields {\"name\":\"h2\",\"link\":\"a@href\"}), frames. Selectors: CSS (shadow DOM, same-origin frames), text=, role=button[name=\"Save\"], xpath=, label=, placeholder=, testid=, a >> b, nth=N. Secret values are never readable. waitFor waits for an element.",
        .step: "Act once the element is visible, enabled, still and not covered: click (modifiers), dblclick, rightclick, hover, focus, type, clear, press (any key or chord like Control+A; selector optional), select (value/values), check, uncheck, submit, scroll (x/y), drag (to, or x/y), upload (files: full paths; a file field, upload button or drop zone). force skips the checks. Secret fields and the clipboard are refused. Uploads refuse private folders, credentials, environment files, keys and app records, including symlink targets. Steps share 300 calls per five minutes per caller across all tabs. Public-site actions need an exact-origin grant.",
        .screenshot: "Save a privacy-masked PNG: the visible page, fullPage, one element (selector), or format pdf. Password and card fields are painted out. Mac paths are refused for remote callers.",
        .handover: "Give the page to the person for sign-in, passwords, payments or CAPTCHA. Agent reads and actions stop until Done or Stop; an unfinished wait returns still-waiting.",
        .close: "Delete a session's named browser window. Deleting B1 leaves B2 called B2."
    ]
    /// The action log keeps what a browser_page call did, never the values it carried
    /// into a site (cookies, storage, mocked bodies, header values).
    public static func loggedPageArguments(_ args: NativeRPCValue) -> NativeRPCValue {
        var out = args
        for key in ["localStorage", "sessionStorage"] where args[key].fields != nil {
            out = out.setting(key, .string("[\(args[key].fields?.count ?? 0) values]"))
        }
        if let cookies = args["cookies"].elements { out = out.setting("cookies", .string("[\(cookies.count) cookies]")) }
        if let headers = args["headers"].fields { out = out.setting("headers", .array(headers.map { .string($0.key) })) }
        if let mocks = args["mock"].elements { out = out.setting("mock", .array(mocks.map { $0.removing("body").removing("json").removing("headers") })) }
        if !args["promptText"].isNullish { out = out.setting("promptText", .string("[text]")) }
        return out
    }

    public static func schema(for verb: BrowserDriverVerb) throws -> NativeRPCValue {
        let target = #""sessionId":{"type":"string"},"window":{"type":"string"}"#
        let properties: String; let required: String
        switch verb {
        case .open: properties = #""url":{"type":"string"},"isolate":{"type":"boolean"},"newWindow":{"type":"boolean"},"# + target; required = #", "required":["url"]"#
        case .read: properties = #""selector":{"type":"string"},"waitFor":{"type":"string"},"timeoutMs":{"type":"number"},"textChars":{"type":"integer"},"mode":{"type":"string","enum":["outline","text","accessibility","links","tables","html","matches","extract","frames"]},"limit":{"type":"integer"},"match":{"type":"string"},"maxChars":{"type":"integer"},"rows":{"type":"string"},"fields":{"type":"object","additionalProperties":{"type":"string"}},"attributes":{"type":"array","items":{"type":"string"}},"# + target; required = ""
        case .step: properties = #""verb":{"type":"string","enum":["click","dblclick","rightclick","hover","focus","type","clear","press","select","check","uncheck","submit","scroll","drag","upload"]},"selector":{"type":"string"},"value":{"type":"string"},"values":{"type":"array","items":{"type":"string"}},"key":{"type":"string"},"modifiers":{"type":"array","items":{"type":"string","enum":["Shift","Control","Alt","Meta"]}},"files":{"type":"array","items":{"type":"string"}},"to":{"type":"string"},"x":{"type":"number"},"y":{"type":"number"},"force":{"type":"boolean"},"timeoutMs":{"type":"number"},"# + target; required = #", "required":["verb"]"#
        case .handover: properties = #""prompt":{"type":"string"},"# + target; required = #", "required":["prompt"]"#
        case .screenshot: properties = #""fullPage":{"type":"boolean"},"selector":{"type":"string"},"format":{"type":"string","enum":["png","pdf"]},"timeoutMs":{"type":"number"},"# + target; required = ""
        case .close: properties = target; required = ""
        }
        return try NativeRPCValue.parseJSON(Data(("{\"type\":\"object\",\"properties\":{" + properties + "},\"additionalProperties\":false" + required + "}").utf8))
    }
    private static let pageSchema = #"""
    {"type":"object","properties":{"action":{"type":"string","enum":["state","navigate","back","forward","reload","stop","zoom","find","findstop","print","devtools","useragent","inspect","record","recording","recordclear","screenshot","reveal","wait","evaluate","dialogs","console","requests","route","emulate","permissions","storage","collect"]},"sessionId":{"type":"string"},"window":{"type":"string"},"url":{"type":"string"},"factor":{"type":"number"},"text":{"type":"string"},"backwards":{"type":"boolean"},"next":{"type":"string"},"keepSelection":{"type":"boolean"},"userAgent":{"type":"string"},"on":{"type":"boolean"},"path":{"type":"string"},"for":{"type":"string","enum":["load","networkidle","url","selector","text","function","download","time"]},"selector":{"type":"string"},"state":{"type":"string","enum":["visible","hidden","attached","detached","enabled"]},"script":{"type":"string"},"arg":{},"world":{"type":"string","enum":["page","isolated"]},"idleMs":{"type":"number"},"timeoutMs":{"type":"number"},"policy":{"type":"string","enum":["ask","accept","dismiss"]},"promptText":{"type":"string"},"once":{"type":"boolean"},"clear":{"type":"boolean"},"since":{"type":"number"},"level":{"type":"string"},"limit":{"type":"number"},"bodies":{"type":"boolean"},"har":{"type":"boolean"},"resources":{"type":"boolean"},"method":{"type":"string"},"block":{"type":"array","items":{"type":"string"}},"types":{"type":"array","items":{"type":"string"}},"mock":{"type":"array","items":{"type":"object","properties":{"url":{"type":"string"},"method":{"type":"string"},"status":{"type":"number"},"body":{"type":"string"},"json":{},"contentType":{"type":"string"},"headers":{"type":"object","additionalProperties":{"type":"string"}},"abort":{"type":"boolean"}},"required":["url"],"additionalProperties":false}},"headers":{"type":"object","additionalProperties":{"type":"string"}},"offline":{"type":"boolean"},"reset":{"type":"boolean"},"viewport":{"type":"object","properties":{"width":{"type":"number"},"height":{"type":"number"}},"required":["width","height"],"additionalProperties":false},"device":{"type":"string","enum":["phone-sm","phone","tablet","tablet-lg","laptop","desktop"]},"landscape":{"type":"boolean"},"colorScheme":{"type":"string","enum":["light","dark","system"]},"locale":{"type":"string"},"timezone":{"type":"string"},"geolocation":{"type":["object","null"],"properties":{"latitude":{"type":"number"},"longitude":{"type":"number"},"accuracy":{"type":"number"}}},"camera":{"type":"string","enum":["ask","deny"]},"microphone":{"type":"string","enum":["ask","deny"]},"mode":{"type":"string","enum":["export","import","clear"]},"localStorage":{"type":"object"},"sessionStorage":{"type":"object"},"cookies":{"type":["array","boolean"]},"rows":{"type":"string"},"fields":{"type":"object","additionalProperties":{"type":"string"}},"scroll":{"type":"boolean"},"maxPages":{"type":"number"},"maxRows":{"type":"number"}},"additionalProperties":false}
    """#
    private static let windowsSchema = #"""
    {"type":"object","properties":{"action":{"type":"string","enum":["list","open","close","attach","detach","reach","unreach"]},"window":{"type":"string"},"sessionId":{"type":"string"},"url":{"type":"string"},"machineId":{"type":"string"},"machineName":{"type":"string"},"kind":{"type":"string","enum":["device","server"]},"port":{"type":"integer"}},"additionalProperties":false}
    """#
}
