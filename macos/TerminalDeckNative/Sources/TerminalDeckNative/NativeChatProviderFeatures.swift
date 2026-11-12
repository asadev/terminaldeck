import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

struct NativeChatProviderFeaturesView: View {
    let sessionID: String
    @Environment(\.dismiss) private var dismiss
    @State private var capabilities = NativeRPCValue.null
    @State private var result = NativeRPCValue.null
    @State private var busy = false
    @State private var error: String?
    @State private var objective = ""
    @State private var budget = ""
    @State private var question = ""
    @State private var target = "uncommitted"
    @State private var reference = ""
    @State private var query = ""
    @State private var conversations: [NativeRPCValue] = []
    @State private var catalogueCursor: String?
    @State private var diffProposals: [NativeRPCValue] = []
    @State private var children: [NativeRPCValue] = []
    @State private var terminals: [NativeRPCValue] = []
    @State private var terminalCursor: String?
    @State private var selectedChild: String?
    @State private var childCursor: String?
    @State private var childListCursor: String?
    @State private var boundSessionID: String?
    @State private var side = NativeChatSideOwner()
    @State private var policySandbox = ""
    @State private var policyApproval = ""
    @State private var claudePolicy = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Provider features").font(.headline); Spacer(); NativeSessionButton("Done") { dismiss() } }
            Text(capabilities["provider"].string?.capitalized ?? "Loading provider…").font(.subheadline)
            Text(capabilities["reason"].string ?? "Checking this session's helper…").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if busy { ProgressView("Waiting for the provider…").controlSize(.small) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("Saved provider conversations") {
                        VStack(alignment: .leading) {
                            HStack { NativeSessionTextField("Search conversations", text: $query); NativeSessionButton("Search") { run("catalogue/list", fields: [.init("query", .string(query))]) } }
                            ForEach(Array(conversations.enumerated()), id: \.offset) { _, row in
                                HStack(alignment: .top) {
                                    Text(row["preview"].string ?? row["title"].string ?? row["conversationId"].string ?? "Conversation").lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                                    NativeSessionButton("Preview") { preview(row) }
                                    if sessionID != "hoot" { NativeSessionButton("Resume") { resume(row) } }
                                }.font(.caption)
                            }
                            if let next = catalogueCursor { NativeSessionButton("Next page") { run("catalogue/list", fields: [.init("query", .string(query)), .init("cursor", .string(next))]) } }
                        }.padding(4)
                    }
                    HStack { NativeSessionButton("Enabled skills") { run("skills/list") }; NativeSessionButton("Instruction sources") { run("instructions/read") } }
                    providerBoundaries
                    GroupBox("Provider goal") {
                        VStack {
                            NativeSessionTextField("Objective", text: $objective, axis: .vertical).lineLimit(2...4)
                            HStack { NativeSessionTextField("Token budget (optional)", text: $budget); NativeSessionButton("Save") {
                                var fields = [NativeRPCValue.Field("objective", .string(objective))]
                                if !budget.isEmpty { guard let number = Double(budget), number.isFinite, number > 0, number.rounded() == number else { error = "Enter a positive whole token budget."; return }; fields.append(.init("tokenBudget", .number(number))) }
                                run("goals/set", fields: fields)
                            }.disabled(objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                            HStack { NativeSessionButton("Read") { run("goals/read") }; NativeSessionButton("Pause") { run("goals/pause") }; NativeSessionButton("Resume") { run("goals/resume") }; NativeSessionButton("Clear") { run("goals/clear") }; Spacer() }
                        }.padding(4)
                    }
                    GroupBox("Side question") {
                        VStack(alignment: .leading) {
                            Text("Separate, temporary, read-only provider fork. Its transcript is removed on close.").font(.caption).foregroundStyle(.secondary)
                            HStack { NativeSessionButton("Open") { run("side/open") }; NativeSessionButton("Read reply") { run("side/read") }; NativeSessionButton("Close") { run("side/close") } }
                            HStack { NativeSessionTextField("Question", text: $question, axis: .vertical); NativeSessionButton("Send") { run("side/send", fields: [.init("text", .string(question))]) } }.disabled(question.isEmpty)
                        }.padding(4)
                    }
                    GroupBox("Review") {
                        VStack {
                            Picker("Scope", selection: $target) { Text("Uncommitted").tag("uncommitted"); Text("Base branch").tag("baseBranch"); Text("Commit").tag("commit"); Text("Custom").tag("custom") }.pickerStyle(.segmented)
                            if target != "uncommitted" { NativeSessionTextField(target == "baseBranch" ? "Base branch" : target == "commit" ? "Commit hash" : "Review instructions", text: $reference) }
                            NativeSessionButton("Start provider review") { run("review/start", fields: [.init("target", .string(target)), .init(target == "baseBranch" ? "branch" : target == "commit" ? "sha" : "instructions", .string(reference))]) }
                        }.padding(4)
                    }
                    // Provider connections and provider voice live under Connections and Voice in the chat's ⋯ menu (17 Oct 2026).
                    if sessionID != "hoot" { fileChanges }
                    if sessionID != "hoot" { NativeChatSessionExtrasView(sessionID: boundSessionID ?? sessionID) }
                    childConversations
                    providerTerminals
                    NativeChatOwnedTerminalsView(sessionID: boundSessionID ?? sessionID)
                    if !result.isNullish { GroupBox("Provider response") { NativeChatProviderResult(value: result).frame(maxWidth: .infinity, alignment: .leading).padding(4) } }
                }.disabled(busy || capabilities.isNullish).padding(2)
            }
        }.padding(20).frame(width: 680, height: 720)
            .task { do { capabilities = try await call("capabilities"); boundSessionID = capabilities["serviceSessionId"].string } catch { self.error = error.localizedDescription } }
            // Closing the window ends only a side conversation it opened, never one the provider tool opened.
            .onDisappear { if boundSessionID != nil, side.opened { Task { _ = try? await call("side/close") } } }
    }
    private var providerTerminals: some View {
        GroupBox("Provider terminals") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recorded thread-owned commands only. Creating, writing, resizing and bringing a terminal to the foreground need a scoped provider transport that is not currently available.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    NativeSessionButton("Read terminal capabilities") { run("terminals/capabilities") }
                    NativeSessionButton("List owned terminals") { terminal("list") }
                    NativeSessionButton("Clean thread terminals") { terminal("clean") }
                }
                ForEach(Array(terminals.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row["command"].string ?? row["itemId"].string ?? "Owned terminal").font(.callout).textSelection(.enabled)
                        HStack {
                            NativeSessionButton("Read output") { terminal("read", row: row) }
                            NativeSessionButton("Stop this terminal") { terminal("stop", row: row) }
                        }
                    }
                }
                if let cursor = terminalCursor { NativeSessionButton("Next terminals") { terminal("list", cursor: cursor) } }
            }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func terminal(_ action: String, row: NativeRPCValue = .null, cursor: String? = nil) {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                var fields: [NativeRPCValue.Field] = []
                if let process = row["processId"].string { fields.append(.init("processId", .string(process))) }
                if let item = row["itemId"].string { fields.append(.init("itemId", .string(item))) }
                if let cursor { fields.append(.init("cursor", .string(cursor))) }
                result = try await call("terminals/" + action, fields: fields)
                if action == "list" { terminals = result["terminals"].elements ?? []; terminalCursor = result["nextCursor"].string }
            } catch { self.error = error.localizedDescription }
        }
    }
    private var providerBoundaries: some View {
        GroupBox("Provider boundaries") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Only provider-reported fields count as confirmed. The app's permissions stay separate. Changes affect the current provider session; saved app choices can apply again after reconnect.").font(.caption).foregroundStyle(.secondary)
                NativeSessionButton("Read effective provider policy") { run("policy/read") }
                if capabilities["provider"].string == "codex" {
                    Picker("Sandbox", selection: $policySandbox) { Text("Keep current").tag(""); Text("Read only").tag("read-only"); Text("Workspace write").tag("workspace-write"); Text("Full access").tag("danger-full-access") }
                    Picker("Approval", selection: $policyApproval) { Text("Keep current").tag(""); Text("Untrusted").tag("untrusted"); Text("On request").tag("on-request"); Text("Never ask").tag("never") }
                    NativeSessionButton("Apply provider boundary change") {
                        var fields: [NativeRPCValue.Field] = []
                        if !policySandbox.isEmpty { fields.append(.init("sandbox", .string(policySandbox))) }
                        if !policyApproval.isEmpty { fields.append(.init("approvalPolicy", .string(policyApproval))) }
                        run("policy/change", fields: fields)
                    }.disabled(policySandbox.isEmpty && policyApproval.isEmpty)
                } else if capabilities["provider"].string == "claude" {
                    Picker("Provider permission mode", selection: $claudePolicy) { Text("Keep current").tag(""); Text("Default").tag("default"); Text("Accept edits").tag("acceptEdits"); Text("Plan").tag("plan"); Text("Bypass permissions").tag("bypassPermissions") }
                    NativeSessionButton("Apply provider permission mode") { run("policy/change", fields: [.init("mode", .string(claudePolicy))]) }.disabled(claudePolicy.isEmpty)
                }
            }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var childConversations: some View {
        GroupBox("Provider child conversations") {
            VStack(alignment: .leading, spacing: 8) {
                NativeSessionButton("Read child tasks") { child("list") }
                ForEach(Array(children.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row["title"].string ?? row["name"].string ?? row["description"].string ?? row["id"].string ?? "Child task").font(.callout)
                        Text(row["status"].string ?? "Status not reported").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            NativeSessionButton("Read conversation") { child("read", task: row["id"].string ?? row["taskId"].string) }
                            if sessionID != "hoot" { NativeSessionButton("Resume in Chat") { child("resume", task: row["id"].string ?? row["taskId"].string) }.disabled(row["canResume"].bool != true) }
                        }
                    }
                }
                if let cursor = childListCursor { NativeSessionButton("Next child tasks") { child("list", cursor: cursor) } }
                if let cursor = childCursor, let selectedChild { NativeSessionButton("Next child messages") { child("read", task: selectedChild, cursor: cursor) } }
            }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func child(_ action: String, task: String? = nil, cursor: String? = nil) {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                var fields: [NativeRPCValue.Field] = []
                if let task { fields.append(.init("taskId", .string(task))) }
                if let cursor { fields.append(.init("cursor", .string(cursor))) }
                if action == "resume" {
                    result = try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("session:chat:children", [sessionID, action, NativeRPCValue.object(fields).foundation]))
                    if let created = result["session"].foundation as? [String: Any], let id = created["id"] as? String {
                        AppModel.shared.buttonActions.created(created); AppModel.shared.select(id)
                    }
                    if result["resumed"].bool != true { error = result["warning"].string ?? "The provider did not confirm the child's exact saved conversation." }
                    else { dismiss() }
                } else {
                    result = try await call("children/" + action, fields: fields)
                    if action == "list" { children = result["items"].elements ?? result["children"].elements ?? result["tasks"].elements ?? []; childListCursor = result["nextCursor"].string }
                    else { selectedChild = task; childCursor = result["nextCursor"].string }
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    private var fileChanges: some View {
        GroupBox("Conditional file changes") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Uses exact recorded text versions. Finish the turn and background writers before Apply or Reject. Other edits are kept.").font(.caption).foregroundStyle(.secondary)
                NativeSessionButton("Read recorded changes") { diff("list") }
                ForEach(Array(diffProposals.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row["path"].string ?? "Recorded change").font(.callout).textSelection(.enabled)
                        Text(row["state"].string ?? "Versioned proposal").font(.caption).foregroundStyle(.secondary)
                        HStack { NativeSessionButton("Preview change") { diff("preview", id: row["id"].string) }; NativeSessionButton("Apply") { diff("apply", id: row["id"].string) }.disabled(row["canApply"].bool != true); NativeSessionButton("Reject") { diff("reject", id: row["id"].string) }.disabled(row["canReject"].bool != true) }
                    }
                }
            }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func diff(_ action: String, id: String? = nil) {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                let args = NativeRPCValue.object([.init("id", id.map(NativeRPCValue.string) ?? .null)])
                result = try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("session:chat:diffs", [sessionID, action, args.foundation]))
                if result["verified"].bool == false { error = "The file action returned, but its final bytes could not be verified. Read the file before another action." }
                if action == "list" { diffProposals = result["items"].elements ?? [] }
                else if let changed = result["id"].string { diffProposals = diffProposals.map { $0["id"].string == changed ? result : $0 } }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func preview(_ row: NativeRPCValue) {
        run("catalogue/read", fields: [.init("conversationId", row["conversationId"]), .init("path", row["path"])])
    }
    private func resume(_ row: NativeRPCValue) {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                _ = try await call("catalogue/read", fields: [.init("conversationId", row["conversationId"]), .init("path", row["path"])])
                let inventory = try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("session:list"))
                guard let source = inventory.elements?.first(where: { $0["id"].string == sessionID }), source["provider"].string == row["provider"].string, source["cwd"].string == row["cwd"].string else { throw NativeRPCError.invalidArguments("This source session changed. Reload its conversation catalogue.") }
                guard source["profileId"].string?.isEmpty == false else { throw NativeRPCError(code: "account-scope-unavailable", message: "The source Chat has no recorded account identity. Choose its account explicitly in New Session; no default was substituted.") }
                var input = NativeRPCValue.object([.init("cwd", row["cwd"]), .init("provider", row["provider"]), .init("chat", .bool(true)), .init("resume", .bool(true)), .init("resumeConversationId", row["conversationId"]), .init("cols", .number(100)), .init("rows", .number(30))])
                for key in ["profileId", "homeProfileId", "projectId"] where !source[key].isNullish { input = input.setting(key, source[key]) }
                guard let created = try await EngineBridge.shared.invoke("session:create", [input.foundation]) as? [String: Any], let id = created["id"] as? String else { throw NativeRPCError.malformed("The session launch was not confirmed.") }
                AppModel.shared.buttonActions.created(created); AppModel.shared.select(id)
                let confirmed = try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("session:chat:ensure", [id]))
                guard confirmed["providerConversationId"].string == row["conversationId"].string else { throw NativeRPCError(code: "resume-unconfirmed", message: "The provider did not confirm this exact saved conversation. Check the new tab before sending.") }
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
    static func call(_ target: String, _ operation: String, fields: [NativeRPCValue.Field] = []) async throws -> NativeRPCValue {
        let arguments: [Any?] = target == "hoot" ? [operation, NativeRPCValue.object(fields).foundation] : [target, operation, NativeRPCValue.object(fields).foundation]
        return try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke(target == "hoot" ? "hoot:chat:provider" : "session:chat:provider", arguments))
    }
    private func call(_ operation: String, fields: [NativeRPCValue.Field] = []) async throws -> NativeRPCValue {
        try await Self.call(boundSessionID ?? sessionID, operation, fields: fields)
    }
    private func run(_ operation: String, fields: [NativeRPCValue.Field] = []) {
        busy = true; error = nil
        Task { defer { busy = false }; do { result = try await call(operation, fields: fields); side.record(operation); if operation == "catalogue/list" { conversations = result["items"].elements ?? []; catalogueCursor = result["nextCursor"].string } } catch { self.error = error.localizedDescription } }
    }
}

/// The provider's own plugins, apps and MCP servers: the Provider tab of Connections (one entry per job, 17 Oct 2026).
struct NativeChatProviderConnectionsView: View {
    let sessionID: String
    @State private var capabilities = NativeRPCValue.null
    @State private var boundSessionID: String?
    @State private var result = NativeRPCValue.null
    @State private var busy = false
    @State private var error: String?
    @State private var connectionID = ""
    @State private var server = ""
    @State private var marketplace = ""
    @State private var pluginName = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Provider connections").font(.headline)
            Text(capabilities["reason"].string ?? "Checking this session's helper…").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if busy { ProgressView("Waiting for the provider…").controlSize(.small) }
            VStack(alignment: .leading) {
                HStack { NativeSessionButton("Plugins") { run("connections/plugins") }; NativeSessionButton("Apps") { run("connections/apps") }; NativeSessionButton("Installed plugins") { run("connections/installedPlugins") } }
                NativeSessionTextField("Exact ID from provider inventory", text: $connectionID)
                HStack { NativeSessionButton("Enable plugin") { enable(plugin: true, enabled: true) }; NativeSessionButton("Disable plugin") { enable(plugin: true, enabled: false) }; NativeSessionButton("Enable app") { enable(plugin: false, enabled: true) }; NativeSessionButton("Disable app") { enable(plugin: false, enabled: false) } }.disabled(connectionID.isEmpty)
                HStack { NativeSessionTextField("Marketplace path from plugin inventory", text: $marketplace); NativeSessionTextField("Plugin name", text: $pluginName) }
                HStack { NativeSessionButton("Read plugin") { plugin("connections/plugin") }; NativeSessionButton("Install plugin") { plugin("connections/installPlugin") }; NativeSessionButton("Uninstall plugin") { run("connections/uninstallPlugin", fields: [.init("id", .string(connectionID))]) }.disabled(connectionID.isEmpty) }
                NativeSessionTextField("MCP server name", text: $server)
                HStack { NativeSessionButton("Provider MCP status") { run("mcp/status") }; NativeSessionButton("Connection details") { mcp("mcp/details") }.disabled(server.isEmpty); NativeSessionButton("Provider sign-in") { mcp("mcp/auth") }.disabled(server.isEmpty); NativeSessionButton("Reconnect") { mcp("mcp/reconnect") }.disabled(server.isEmpty) }
                NativeSessionButton("Reload provider MCP configuration") { mcp("mcp/reconnect", reload: true) }.disabled(server.isEmpty)
                if let address = result["authorizationUrl"].string ?? result["authUrl"].string, let url = URL(string: address), ["https", "http"].contains(url.scheme), url.user == nil, url.password == nil { Link("Continue provider sign-in", destination: url) }
            }.disabled(busy || capabilities.isNullish)
            if !result.isNullish { ScrollView { NativeChatProviderResult(value: result).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 240) }
        }.padding(16).frame(width: 640)
            .task { do { capabilities = try await NativeChatProviderFeaturesView.call(sessionID, "capabilities"); boundSessionID = capabilities["serviceSessionId"].string } catch { self.error = error.localizedDescription } }
    }
    private func mcp(_ operation: String, reload: Bool = false) {
        var fields = [NativeRPCValue.Field("name", .string(server))]
        if reload { fields.append(.init("mode", .string("reloadConfiguration"))) }
        run(operation, fields: fields)
    }
    private func plugin(_ operation: String) { run(operation, fields: [.init("marketplacePath", .string(marketplace)), .init("pluginName", .string(pluginName))]) }
    private func enable(plugin: Bool, enabled: Bool) { run(plugin ? "connections/enablePlugin" : "connections/enableApp", fields: [.init("id", .string(connectionID)), .init("enabled", .bool(enabled))]) }
    private func run(_ operation: String, fields: [NativeRPCValue.Field] = []) {
        busy = true; error = nil
        Task { defer { busy = false }; do { result = try await NativeChatProviderFeaturesView.call(boundSessionID ?? sessionID, operation, fields: fields) } catch { self.error = error.localizedDescription } }
    }
}

/// Bounded, selectable provider receipts; secret fields are stripped by backend adapters.
struct NativeChatProviderResult: View {
    let value: NativeRPCValue
    var depth = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let text = value.string { Text(text).textSelection(.enabled) }
            else if let fields = value.fields, depth < 7 {
                ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                    if !field.value.isNullish { HStack(alignment: .top) { Text(field.key).fontWeight(.medium).frame(width: 120, alignment: .leading); if ["installUrl", "authorizationUrl"].contains(field.key), let text = field.value.string, let url = URL(string: text), ["https", "http"].contains(url.scheme), url.user == nil, url.password == nil { Link("Open provider connection", destination: url) } else { AnyView(NativeChatProviderResult(value: field.value, depth: depth + 1)) } } }
                }
            } else if let rows = value.elements, depth < 7 {
                ForEach(Array(rows.prefix(200).enumerated()), id: \.offset) { _, row in AnyView(NativeChatProviderResult(value: row, depth: depth + 1)).padding(.bottom, 6) }
                if rows.count > 200 { Text("Showing the first 200 of \(rows.count) entries.").foregroundStyle(.secondary) }
            } else if let number = value.number { Text(number.formatted()) }
            else if let boolean = value.bool { Text(boolean ? "Yes" : "No") }
            else if value.fields != nil || value.elements != nil { Text("Nested details exceed this preview. The provider tool returns the structured record.").foregroundStyle(.secondary) }
        }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
    }
}
