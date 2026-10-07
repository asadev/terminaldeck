import Foundation
import TerminalDeckNativeCore

extension BackendDeckToolsSessionsArea {
    public static func windowDefinitions(runtime: any BackendDeckToolsSessionsRuntime, windows: any BackendDeckToolsSessionsWindows) throws -> [BackendDeckToolsDefinition] {
        try definitions(module: "session-window-tools.ts", runtime: runtime) { entry, context, args in
            if entry.id == "windows.list" {
                try await authorize(entry, summary: "List the session windows and displays", args: args, runtime: runtime, context: context)
                let view = try await windows.view(context: context)
                return .init(view, summary: object([("windows", .number(Double(view["windows"].elements?.count ?? 0))), ("displays", .number(Double(view["displays"].elements?.count ?? 0)))]))
            }
            let id = try Args.str(args, "sessionId")
            var summary = "Move session \(id) back to the main window"
            if entry.id == "windows.pop_out" {
                let display = args["display"]
                summary = "Move session \(id) into its own window" + (display.isNullish || display.string == "" ? "" : " on \(display.string ?? display.compact)")
            }
            try await authorize(entry, summary: summary, args: args, runtime: runtime, context: context)
            let held = try await session(id, runtime: runtime, context: context), sid = held["id"].string ?? ""
            let result: NativeRPCValue
            if entry.id == "windows.pop_out" {
                let view = try await windows.view(context: context)
                result = try await windows.open(sessionID: sid, displayID: Rules.displayID(args["display"], view: view), context: context)
            } else { result = try await windows.dock(sessionID: sid, context: context) }
            guard result["ok"].bool == true else { throw refused(result["message"].string ?? "") }
            let returned = result["sessionId"], message = result["message"]
            var value = object([("sessionId", returned), ("message", message)]), resultSummary = object([("sessionId", returned)])
            if entry.id == "windows.pop_out" {
                let display = result["display"].isNullish ? NativeRPCValue.null : result["display"]
                value = value.setting("display", display); resultSummary = resultSummary.setting("display", display)
            }
            return .init(value, summary: resultSummary)
        }
    }
    public static func askerName(caller: BackendDeckToolsSessionsCaller, slots: [String]) -> String {
        if caller.kind == .session, caller.sessionID != nil {
            if let slot = slots.first { return "The session driving \(slot)" }
            return "A session in this app"
        }
        if caller.kind == .key { return "“\(caller.keyName ?? "An AI app")”, an AI app you gave a key to" }
        return "Hoot"
    }
    public static func mayAskLift(caller: BackendDeckToolsSessionsCaller, attended: Bool) throws {
        guard caller.kind == .session && caller.sessionID != nil || caller.actsAsOwner else {
            throw refused("browser.lift_request only works for sessions at this machine. Asking for a person’s logins from a paired device is not something this app does. Say what you would have done and let them do it.", code: "not-granted")
        }
        guard attended else {
            throw refused("browser.lift_request puts a question about the person’s logins in front of them, and there is nobody at the machine to answer it. Do not retry and do not look for another way. Say in your report what you would have asked.", code: "not-permitted-unattended")
        }
    }
    public static func liftDefinitions(runtime: any BackendDeckToolsSessionsRuntime, requests: any BackendDeckToolsSessionsLiftRequests) throws -> [BackendDeckToolsDefinition] {
        try definitions(module: "lift-ask-tool.ts", runtime: runtime) { entry, context, args in
            let caller = try await runtime.caller(context)
            try mayAskLift(caller: caller, attended: context.attended)
            let from = args["from"].string ?? ""
            guard !from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw refused("from names the profile whose session you are asking about") }
            try await authorize(entry, summary: "Ask for a session lift from \(from.isEmpty ? "?" : from)", args: args, runtime: runtime, context: context)
            var into: [String] = []
            if !args["into"].isNullish {
                guard let list = args["into"].elements, list.allSatisfy({ $0.string != nil }) else { throw refused("into must be an array of worker names") }
                into = list.compactMap(\.string)
            }
            let slots = caller.kind == .session && caller.sessionID != nil ? try await runtime.browserSlots(sessionID: caller.sessionID ?? "", machineID: caller.machineID ?? "", context: context) : []
            let answer = try await requests.file(askedBy: askerName(caller: caller, slots: slots), from: from, into: into, reason: args["reason"], context: context)
            guard answer["ok"].bool == true else { throw refused(answer["reason"].string ?? "") }
            let repeated = answer["repeated"].bool == true
            let note = repeated ? "You already asked this. The same request is still waiting in the person’s Scraping panel — do not ask again; report that it is pending." : "The ask is in the person’s Scraping panel now, with Approve and Decline beside it. They may also do nothing. Do not retry; report that you asked."
            return .init(object([("asked", .bool(true)), ("repeated", .bool(repeated)), ("requestId", answer["request"]["id"]), ("from", answer["fromName"]), ("into", answer["intoNames"]), ("note", .string(note)), ("empty", .bool(false)), ("emptyReason", .string(""))]), summary: object([("asked", .number(1)), ("repeated", .bool(repeated)), ("empty", .bool(false))]))
        }
    }
}
