import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

struct NativeChatApprovalCard: View {
    let request: NativeRPCValue
    let disabled: Bool
    let answer: (Bool, NativeRPCValue) -> Void
    @State private var scope = ""
    @State private var comment = ""
    private var details: NativeRPCValue { BackendChatApproval.details(request) }
    private var scopes: [BackendChatApproval.Scope] {
        BackendChatApproval.scopes(request).filter { !BackendChatApproval.isRememberedScope(request, scope: $0.id) || request["approvalNonce"].string?.isEmpty == false }
    }
    private var chosen: String { scope.isEmpty ? (scopes.count == 1 ? scopes[0].id : BackendChatApproval.defaultScope(request)) : scope }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Permission").font(.headline)
            Text(request["name"].string ?? "Tool operation").fontWeight(.medium).lineLimit(2)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let reason = details["reason"].string { Text(reason).fixedSize(horizontal: false, vertical: true) }
                    if let cwd = details["cwd"].string { Text("Folder: " + cwd).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    if let path = details["blockedPath"].string { Text("Requested path: " + path).font(.caption).textSelection(.enabled) }
                    if let command = details["command"].string { code(command) }
                    if details["input"]["permissions"].fields != nil { code(details["input"]["permissions"].compact) }
                    if request["subtype"].string == "item/fileChange/requestApproval", (details["diffs"].elements ?? []).isEmpty {
                        Text("The provider did not include a diff for this request. Review the operation arguments.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(details["diffs"].elements ?? [], id: \.compact) { diff in diffView(diff) }
                    DisclosureGroup("Operation arguments") { code(details["input"].compact) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 5)
            }.frame(maxHeight: 240)
            if scopes.count > 1 {
                Picker("Allow scope", selection: $scope) {
                    Text("Choose…").tag("")
                    ForEach(scopes) { Text($0.title).tag($0.id) }
                }.onAppear { scope = scopes.contains(where: { $0.id == BackendChatApproval.defaultScope(request) }) ? BackendChatApproval.defaultScope(request) : "" }
            }
            if let selected = scopes.first(where: { $0.id == chosen }) { Text(selected.detail).font(.caption).foregroundStyle(.secondary) }
            if request["approvalNonce"].string == nil, BackendChatApproval.scopes(request).contains(where: { BackendChatApproval.isRememberedScope(request, scope: $0.id) }) {
                Text("Remembered approvals need the updated session helper.").font(.caption).foregroundStyle(.secondary)
            }
            if !BackendChatApproval.updates(request, scope: chosen).isEmpty {
                Text("Rules to remember").font(.caption).foregroundStyle(.secondary)
                ScrollView { code(NativeRPCValue.array(BackendChatApproval.updates(request, scope: chosen)).compact) }.frame(maxHeight: 100)
            } else if request["subtype"].string == "item/commandExecution/requestApproval", chosen.hasPrefix("decision:") {
                ScrollView { code(BackendChatApproval.codexDecision(request, allowed: true, scope: chosen).compact) }.frame(maxHeight: 100)
            }
            if BackendChatApproval.supportsComment(request) {
                NativeSessionTextField("Reason if denied (optional)", text: $comment, axis: .vertical).lineLimit(1...3).textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                NativeSessionButton(BackendChatApproval.codexDecision(request, allowed: false, scope: "once").string == "cancel" ? "Cancel turn" : "Deny") {
                    answer(false, payload(allowed: false))
                }.buttonStyle(.bordered)
                NativeSessionButton(scopes.first(where: { $0.id == chosen })?.title ?? "Allow once") {
                    answer(true, payload(allowed: true))
                }.buttonStyle(.borderedProminent).disabled(!scopes.contains(where: { $0.id == chosen }))
            }
        }.font(.system(size: 12)).padding(12).background(.background, in: .rect(cornerRadius: 12)).disabled(disabled)
    }
    private func payload(allowed: Bool) -> NativeRPCValue {
        var value = NativeRPCValue.object([.init("scope", .string(allowed ? chosen : "once"))])
        if !allowed && !comment.isEmpty { value = value.setting("comment", .string(comment)) }
        if request.has("approvalNonce") { value = value.setting("approvalNonce", request["approvalNonce"]) }
        return value
    }
    private func code(_ text: String) -> some View {
        Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func diffView(_ diff: NativeRPCValue) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(diff["path"].string ?? "File change").fontWeight(.medium)
            if diff["known"].bool != true { Text("The provider did not include a diff. Review the operation arguments.").foregroundStyle(.secondary) }
            ForEach(Array((diff["lines"].elements ?? []).enumerated()), id: \.offset) { _, line in
                let kind = line["kind"].string ?? "same"
                Text((kind == "add" ? "+ " : kind == "del" ? "− " : "  ") + (line["text"].string ?? ""))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(kind == "add" ? Color.green : kind == "del" ? Color.red : Color.primary)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            if diff["truncated"].bool == true { Text("Diff preview shortened; full details are in Operation arguments.").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
