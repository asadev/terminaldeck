import SwiftUI
import TerminalDeckNativeCore

/// The native owner's saved-agent form. MCP exposes the identical policy value
/// through agents.settings_get/set(tool_use_restrictions).
struct NativeToolUseRestrictionsEditor: View {
    @Binding var value: NativeRPCValue?
    let agentName: String
    let busy: Bool
    @State private var tool = ""
    @State private var arguments = "{}"
    @State private var problem: String?
    private var policy: ToolUseRestrictions? { value.flatMap { try? ToolUseRestrictions($0) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Who can use this?").font(.headline)
            Text("These rules apply to \(agentName.isEmpty ? "this saved agent" : agentName)'s verified task and named-profile sessions in Deck.").font(.caption)
            Text("Other tools still follow existing access. This cannot grant a missing tool, folder or permission. External keys and Hoot keep their own access. It does not limit Bash or files outside Deck's tool door.").font(.caption).foregroundStyle(.secondary)
            if let invalid = ToolUseRestrictions.problem(value) {
                Text(invalid).font(.caption).foregroundStyle(DeckTokens.bad)
                NativeSessionButton("Clear invalid rules (owner repair)") { value = nil; problem = nil }.disabled(busy)
            } else {
                if policy?.rules.isEmpty != false { Text("No extra Deck tool rules.").font(.caption).foregroundStyle(.secondary) }
                ForEach(policy?.rules ?? [], id: \.tool) { rule in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(rule.service + " · " + rule.tool).font(.callout.bold()); Spacer(); NativeSessionButton("Remove restriction") { remove(rule.tool) }.disabled(busy) }
                        if rule.cases.isEmpty { Text("Blocked for this agent.").font(.caption).foregroundStyle(DeckTokens.bad) }
                        ForEach(Array(rule.cases.enumerated()), id: \.offset) { index, item in
                            HStack(alignment: .top) {
                                Text("Only this complete call: " + item["arguments"].compact).font(.system(.caption, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                NativeSessionButton("Remove case") { removeCase(rule.tool, index) }.disabled(busy)
                            }
                        }
                    }.padding(.vertical, 4)
                }
                NativeSessionTextField("Canonical tool, e.g. tasks.comment", text: $tool).textFieldStyle(.roundedBorder).disabled(busy)
                Text("Canonical IDs are checked when saved; aliases and unknown IDs are refused.").font(.caption).foregroundStyle(.secondary)
                Text("Complete arguments as JSON. Include the action and every field the call will send; extra fields are refused.").font(.caption).foregroundStyle(.secondary)
                NativeSessionTextEditor(text: $arguments).font(.system(.caption, design: .monospaced)).frame(minHeight: 70, maxHeight: 120).disabled(busy)
                HStack {
                    NativeSessionButton("Allow this exact call") { add(blocked: false) }.disabled(busy || tool.isEmpty)
                    NativeSessionButton("Block this tool") { add(blocked: true) }.disabled(busy || tool.isEmpty)
                }
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(DeckTokens.bad) }
        }
    }
    private func add(blocked: Bool) {
        do {
            let name = tool.trimmingCharacters(in: .whitespacesAndNewlines)
            let full: NativeRPCValue
            if blocked { full = .object([]) } else { full = try NativeRPCValue.parseJSON(Data(arguments.utf8), maximumBytes: 65536) }
            var list = policy?.raw["tools"].elements ?? []
            let index = list.firstIndex { $0["tool"].string == name }
            var cases = index.map { list[$0]["cases"].elements ?? [] } ?? []
            if blocked { cases = [] } else {
                let next = NativeRPCValue.object([.init("arguments", full)])
                if !cases.contains(where: { ToolUseRestrictions.equal($0, next) }) { cases.append(next) }
            }
            let rule = NativeRPCValue.object([.init("service", .string(name.split(separator: ".").dropLast().joined(separator: "."))), .init("tool", .string(name)), .init("cases", .array(cases))])
            if let index { list[index] = rule } else { list.append(rule) }
            let next = NativeRPCValue.object([.init("version", .number(1)), .init("tools", .array(list))])
            _ = try ToolUseRestrictions(next); value = next; problem = nil
        } catch { problem = error.localizedDescription }
    }
    private func remove(_ name: String) {
        guard let policy else { return }
        value = policy.raw.setting("tools", .array(policy.raw["tools"].elements?.filter { $0["tool"].string != name } ?? []))
    }
    private func removeCase(_ name: String, _ index: Int) {
        guard let policy else { return }
        let list = (policy.raw["tools"].elements ?? []).map { rule -> NativeRPCValue in
            guard rule["tool"].string == name else { return rule }
            return rule.setting("cases", .array((rule["cases"].elements ?? []).enumerated().filter { $0.offset != index }.map(\.element)))
        }
        value = policy.raw.setting("tools", .array(list))
    }
}
