import Foundation
import TerminalDeckNativeCore

/// The panel projects one actual scanner report, including agent variants.
/// Scanning/fixing must be the same authority-scoped services the local UI uses.
public enum BackendRemotePanelReadiness {
    public typealias Scan = @Sendable (String, NativeRPCContext) async throws -> NativeRPCValue
    public typealias Fix = @Sendable (String, String, NativeRPCContext) async throws -> NativeRPCValue
    public static let fixes: Set<String> = ["create-claude-md", "create-agents-md", "create-gemini-md", "create-readme", "create-gitignore", "patch-gitignore", "git-init", "ignore-secrets", "untrack-secrets", "add-test-script", "replace-test-script", "add-typecheck-script", "add-lint-script", "create-lockfile", "upgrade-agent-cli"]
    public static func provider(service: BackendReadinessService, staleAgents: (@Sendable (NativeRPCContext) async throws -> [NativeRPCValue])? = nil) -> BackendRemotePanelProvider {
        provider(scan: { path, context in BackendReadinessService.wire(try await service.scan(project: path, context: context)) },
                 fix: nil, staleAgents: staleAgents)
    }
    public static func provider(scan: @escaping Scan, fix: Fix? = nil,
                                staleAgents: (@Sendable (NativeRPCContext) async throws -> [NativeRPCValue])? = nil) -> BackendRemotePanelProvider {
        let read: @Sendable (BackendRemotePanelRequest, NativeRPCContext) async throws -> NativeRPCValue = { request, context in
            var notes: [String] = [], machine: [NativeRPCValue] = []
            if let staleAgents {
                do {
                    machine = try await staleAgents(context).map { row in
                        var result = rowValue(title: "\(row["command"].string ?? "Agent") is too old to sign in", detail: row["advice"].string ?? "", value: row["version"].string ?? "unknown", id: "agent-cli:" + (row["command"].string ?? ""), tint: "warn")
                        if fix != nil { result = result.setting("actions", .array([action("upgrade-agent-cli", "Upgrade it")])) }; return result
                    }
                } catch { notes.append("Agent CLI versions could not be read: " + error.localizedDescription) }
            } else { notes.append("Agent CLI versions are not read on this host.") }
            var payload = NativeRPCValue.object([.init("path", .string(request.path)), .init("actions", .array([action("scan", "Scan again")]))])
            do {
                let report = try await scan(request.path, context)
                guard let original = report["checks"].elements, report["score"].number != nil else { throw NativeRPCError.malformed("The readiness scanner did not return its report") }
                let agents = report["agents"].elements ?? []
                let picked = request.scope.flatMap { selected in agents.first { $0["agent"].string == selected } }
                let checks = original.map { check in picked?["check"]["id"] == check["id"] ? picked!["check"] : check }
                let score = picked?["score"].number ?? report["score"].number!
                let band = picked?["band"].string ?? report["band"].string ?? "at-risk"
                let cap = picked?["cappedBy"] ?? report["cappedBy"]
                let applicable = checks.filter { $0["status"].string != "skip" }, passing = applicable.filter { $0["status"].string == "pass" }.count
                let count = "\(passing) of \(applicable.count) applicable check\(applicable.count == 1 ? "" : "s") passing, weighted" + (applicable.count == checks.count ? "." : " · \(checks.count - applicable.count) not applicable here.")
                var detail = (["strong":"Ready", "fair":"Workable", "weak":"Rough", "at-risk":"At risk"][band] ?? band) + " — " + count
                if let cap = cap.string { detail += " Score held at \(Int(score)) by \(cap) — fix that first." }
                if let picked { detail += " Graded for \(picked["label"].string ?? "this agent"), which reads \(picked["file"].string ?? "its instructions")." }
                var rows = [rowValue(title: "AI readiness", detail: detail, value: "\(Int(score)) out of 100", id: "score", tint: band == "strong" ? "ok" : band == "at-risk" ? "bad" : "warn")] + machine
                let ranks = ["fail":0, "warn":1, "pass":2, "skip":3]
                func rank(_ check: NativeRPCValue) -> Int { check["gate"].bool == true && ["fail", "warn"].contains(check["status"].string ?? "") ? -1 : ranks[check["status"].string ?? ""] ?? 3 }
                let sorted = checks.enumerated().sorted { left, right in
                    let a = rank(left.element), b = rank(right.element)
                    if a != b { return a < b }; let aw = left.element["weight"].number ?? 0, bw = right.element["weight"].number ?? 0
                    return aw == bw ? left.offset < right.offset : aw > bw
                }
                for entry in sorted {
                    let check = entry.element, status = check["status"].string ?? "skip", proposal = check["fix"]
                    var detail = check["detail"].string ?? ""
                    if check["gate"].bool == true && status != "pass" { detail += " Nothing else on this list counts for much while this is open — it caps the score." }
                    if let touches = proposal["touches"].elements { detail += " Changes " + touches.compactMap(\.string).joined(separator: ", ") + "." }
                    if proposal == .null && status != "pass", let path = check["opens"].string { detail += " This one is \(path) — it needs a person, not a button." }
                    var row = rowValue(title: check["title"].string ?? "Check", detail: detail,
                        value: ["pass":"Passing", "warn":"Warning", "fail":"Failing", "skip":"Not applicable"][status] ?? status,
                        id: check["id"].string ?? "", tint: ["pass":"ok", "warn":"warn", "fail":"bad"][status])
                    if fix != nil, let id = proposal["id"].string, fixes.contains(id) {
                        var button = action(id, proposal["label"].string ?? "Fix")
                        if proposal["destructive"].bool == true { button = button.setting("kind", .string("destructive")).setting("confirm", proposal["description"]) }
                        row = row.setting("actions", .array([button]))
                    }
                    rows.append(row)
                }
                payload = payload.setting("rows", .array(rows))
                if !agents.isEmpty {
                    let scopes: [NativeRPCValue] = [.object([.init("id", .string("project")), .init("label", .string("Project")), .init("on", .bool(picked == nil))])] + agents.map { .object([.init("id", $0["agent"]), .init("label", $0["label"]), .init("on", .bool(picked?["agent"] == $0["agent"]))]) }
                    payload = payload.setting("scopes", .array(scopes))
                }
            } catch { notes.append("This folder could not be scanned: " + error.localizedDescription); payload = payload.setting("rows", .array(machine)) }
            if !notes.isEmpty { payload = payload.setting("note", .string(notes.joined(separator: " "))) }; return payload
        }
        return .init(read: read, act: { request, context in
            let notice: String
            if request.action == "scan" { notice = "Scanned again." }
            else if !fixes.contains(request.action) { notice = "That is not an action this panel offers." }  // panels/readiness.ts:469
            else {
                guard let fix else { throw NativeRPCError(code: "readiness-action", message: "No native fixer is registered for that action") }
                do { let result = try await fix(request.action == "upgrade-agent-cli" ? "" : request.panel.path, request.action, context); notice = result["message"].string ?? "The fix did not report an outcome." }
                catch { notice = "The fix could not be applied: " + error.localizedDescription }
            }
            let redraw = try await read(request.panel, context); return redraw.setting("notice", .string(notice))
        })
    }
    private static func action(_ id: String, _ label: String) -> NativeRPCValue { .object([.init("id", .string(id)), .init("label", .string(label))]) }
    private static func rowValue(title: String, detail: String, value: String, id: String, tint: String?) -> NativeRPCValue {
        var row = NativeRPCValue.object([.init("title", .string(title)), .init("detail", .string(detail)), .init("value", .string(value)), .init("id", .string(id))])
        if let tint { row = row.setting("status", .string(tint)) }; return row
    }
}
