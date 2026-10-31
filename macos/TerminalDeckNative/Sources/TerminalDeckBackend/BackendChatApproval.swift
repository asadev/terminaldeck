import Foundation
import TerminalDeckNativeCore

/// Provider-supported decisions for one pending operation. No remembered app grants.
public enum BackendChatApproval {
    public struct Scope: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let detail: String
        public var wire: NativeRPCValue { .object([.init("id", .string(id)), .init("title", .string(title)), .init("detail", .string(detail))]) }
    }
    public static func isApproval(_ request: NativeRPCValue) -> Bool {
        guard !BackendChatQuestions.isQuestion(request), !BackendChatPlans.isReview(request) else { return false }
        return ["can_use_tool", "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval", "session/request_permission"].contains(request["subtype"].string ?? "")
    }
    public static func sessionUpdates(_ request: NativeRPCValue) -> [NativeRPCValue] {
        guard request["subtype"].string == "can_use_tool", isApproval(request) else { return [] }
        return (request["permissionSuggestions"].elements ?? []).filter { update in
            update["destination"].string == "session" && operationUpdate(update)
        }
    }
    private static func operationUpdate(_ update: NativeRPCValue) -> Bool {
        if update["type"].string == "addRules" {
            guard update["behavior"].string == "allow", let rules = update["rules"].elements, !rules.isEmpty else { return false }
            return rules.allSatisfy { $0["toolName"].string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
                ($0["ruleContent"].isNullish || $0["ruleContent"].string != nil) }
        }
        guard update["type"].string == "addDirectories", let directories = update["directories"].elements, !directories.isEmpty else { return false }
        return directories.allSatisfy { $0.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
    }
    public static func validGeminiOptions(_ request: NativeRPCValue) -> Bool {
        let options = request["input"]["options"].elements ?? []
        let ids = options.compactMap { $0["optionId"].string }
        return !options.isEmpty && ids.count == options.count && ids.allSatisfy { !$0.isEmpty } && Set(ids).count == ids.count
    }
    public static func updates(_ request: NativeRPCValue, scope: String) -> [NativeRPCValue] {
        guard request["subtype"].string == "can_use_tool", isApproval(request) else { return [] }
        if scope == "session" { return sessionUpdates(request) }
        guard scope.hasPrefix("suggestion:"), let index = Int(scope.dropFirst(11)), index >= 0,
              let values = request["permissionSuggestions"].elements, index < values.count else { return [] }
        return [values[index]]
    }
    private static func amendment(_ value: NativeRPCValue) -> Bool {
        guard value.fields?.count == 1 else { return false }
        if let fields = value["acceptWithExecpolicyAmendment"]["execpolicy_amendment"].elements {
            return !fields.isEmpty && fields.allSatisfy { $0.string?.isEmpty == false }
        }
        let network = value["applyNetworkPolicyAmendment"]["network_policy_amendment"]
        return network["action"].string == "allow" && network["host"].string?.isEmpty == false
    }
    public static func scopes(_ request: NativeRPCValue) -> [Scope] {
        guard isApproval(request) else { return [] }
        let method = request["subtype"].string ?? "", input = request["input"]
        if method == "session/request_permission" {
            let options = input["options"].elements ?? []
            guard validGeminiOptions(request) else { return [] }
            return options.compactMap { option in
                guard let id = option["optionId"].string, ["allow_once", "allow_always"].contains(option["kind"].string ?? "") else { return nil }
                return Scope(id: id, title: option["name"].string ?? (option["kind"].string == "allow_once" ? "Allow once" : "Allow and remember"),
                    detail: option["kind"].string == "allow_once" ? "This operation only." : "Remember using the provider's offered rule.")
            }
        }
        let once = Scope(id: "once", title: method == "item/permissions/requestApproval" ? "Allow for turn" : "Allow once", detail: method == "item/permissions/requestApproval" ? "Requested permissions for this turn." : "This operation only.")
        let offered = input["availableDecisions"].elements
        var result = offered == nil || offered?.contains(.string("accept")) == true || method != "item/commandExecution/requestApproval" ? [once] : []
        if method == "can_use_tool", !sessionUpdates(request).isEmpty {
            result.append(Scope(id: "session", title: "Allow for session", detail: "Apply the tool's offered session rules shown below."))
        } else if method == "item/permissions/requestApproval" || method == "item/fileChange/requestApproval" ||
                    (method == "item/commandExecution/requestApproval" && offered?.contains(.string("acceptForSession")) == true) {
            result.append(Scope(id: "session", title: "Allow for session", detail: "The provider remembers this approval in this session."))
        }
        if method == "can_use_tool" {
            for (index, update) in (request["permissionSuggestions"].elements ?? []).enumerated() where operationUpdate(update) {
                let destination = update["destination"].string ?? ""
                let names = ["projectSettings": "project rule", "localSettings": "local project rule", "userSettings": "user rule", "cliArg": "CLI rule"]
                if let title = names[destination] {
                    result.append(Scope(id: "suggestion:\(index)", title: "Allow + save " + title, detail: "Apply exactly the offered \(destination) change shown below."))
                }
            }
        } else if method == "item/commandExecution/requestApproval" {
            for (index, decision) in (offered ?? []).enumerated() where amendment(decision) {
                result.append(Scope(id: "decision:\(index)", title: decision.has("acceptWithExecpolicyAmendment") ? "Allow + save command rule" : "Allow + remember host",
                    detail: "Apply exactly the provider's offered policy change shown below."))
            }
        }
        return result
    }
    public static func codexDecision(_ request: NativeRPCValue, allowed: Bool, scope: String) -> NativeRPCValue {
        if !allowed {
            let offered = request["input"]["availableDecisions"].elements
            return .string(offered != nil && offered?.contains(.string("decline")) != true && offered?.contains(.string("cancel")) == true ? "cancel" : "decline")
        }
        if scope == "session" { return .string("acceptForSession") }
        if scope.hasPrefix("decision:"), let index = Int(scope.dropFirst(9)), index >= 0,
           let offered = request["input"]["availableDecisions"].elements, index < offered.count { return offered[index] }
        return .string("accept")
    }
    public static func supportsComment(_ request: NativeRPCValue) -> Bool { request["subtype"].string == "can_use_tool" }
    public static func validate(_ request: NativeRPCValue, allowed: Bool, answers: NativeRPCValue) throws {
        guard isApproval(request) else { return }
        guard answers.fields != nil else { throw NativeRPCError.invalidArguments("Approval options must be an object.") }
        let unknown = (answers.fields ?? []).filter { !["scope", "comment", "approvalNonce"].contains($0.key) }
        guard unknown.isEmpty else { throw NativeRPCError.invalidArguments("Unsupported approval option. Use an offered scope and a supported comment.") }
        if answers.has("approvalNonce") {
            guard let nonce = answers["approvalNonce"].string, !nonce.isEmpty, nonce == request["approvalNonce"].string else {
                throw NativeRPCError(code: "stale-approval", message: "The operation changed. Review its current approval request.")
            }
        }
        if answers.has("scope"), answers["scope"].string == nil { throw NativeRPCError.invalidArguments("Approval scope must be text.") }
        if answers.has("comment") {
            guard let comment = answers["comment"].string, comment.utf8.count <= 4096,
                  comment.isEmpty || (supportsComment(request) && !allowed) else {
                throw NativeRPCError.invalidArguments("This provider only supports a comment when denying a Claude tool request.")
            }
        }
        if allowed {
            if request["subtype"].string == "session/request_permission", !answers.has("scope"),
               request["input"]["options"].elements?.contains(where: { $0["kind"].string == "allow_once" }) != true {
                throw NativeRPCError.invalidArguments("This provider did not offer a one-use approval. Choose its remembered rule explicitly.")
            }
            let scope = answers["scope"].string ?? defaultScope(request)
            guard scopes(request).contains(where: { $0.id == scope }) else { throw NativeRPCError.invalidArguments("Choose a scope offered for this operation.") }
            if isRememberedScope(request, scope: scope), request.has("approvalNonce"), !answers.has("approvalNonce") {
                throw NativeRPCError.invalidArguments("Remembered approvals need the current request's approvalNonce.")
            }
        } else if let scope = answers["scope"].string, scope != "once" {
            throw NativeRPCError.invalidArguments("A denial cannot grant session permissions.")
        }
    }
    public static func defaultScope(_ request: NativeRPCValue) -> String {
        if request["subtype"].string == "session/request_permission" {
            return request["input"]["options"].elements?.first(where: { $0["kind"].string == "allow_once" })?["optionId"].string ?? "once"
        }
        return "once"
    }
    public static func requiresRememberedConsent(_ request: NativeRPCValue, allowed: Bool, answers: NativeRPCValue) -> Bool {
        guard allowed, isApproval(request), let scope = answers["scope"].string else { return false }
        return isRememberedScope(request, scope: scope)
    }
    public static func isRememberedScope(_ request: NativeRPCValue, scope: String) -> Bool {
        guard scopes(request).contains(where: { $0.id == scope }) else { return false }
        if request["subtype"].string == "session/request_permission" {
            return request["input"]["options"].elements?.first(where: { $0["optionId"].string == scope })?["kind"].string == "allow_always"
        }
        return scope != "once"
    }
    public static func canApproveOnce(_ request: NativeRPCValue) -> Bool {
        let scope = defaultScope(request)
        return scopes(request).contains(where: { $0.id == scope }) && !isRememberedScope(request, scope: scope)
    }
    public static func details(_ request: NativeRPCValue) -> NativeRPCValue {
        let operation = request["operation"].merging(request["input"]["toolCall"]["rawInput"]).merging(request["input"])
        let method = request["subtype"].string ?? ""
        let tool = method == "item/fileChange/requestApproval" ? "fileChange" : request["name"].string ?? "Tool"
        let event = HootChatEvent(conversationID: "approval", turnID: "approval", sequence: 1, provider: .claude,
            record: .init(.toolCall, id: "operation", value: .object([.init("name", .string(tool)), .init("input", operation)])))
        return .object([
            .init("name", request["name"]), .init("command", operation["command"]),
            .init("cwd", operation["cwd"].isNullish ? request["cwd"] : operation["cwd"]),
            .init("reason", operation["reason"].isNullish ? (request["reason"].isNullish ? request["description"] : request["reason"]) : operation["reason"]),
            .init("blockedPath", request["blockedPath"]), .init("input", operation),
            .init("diffs", .array(BackendChatDiffs.cards(HootChatProjection.rows([event])).map(\.wire))),
            .init("scopes", .array(scopes(request).map(\.wire))), .init("denialComment", .bool(supportsComment(request))),
            .init("sessionUpdates", .array(sessionUpdates(request)))
        ])
    }
}
