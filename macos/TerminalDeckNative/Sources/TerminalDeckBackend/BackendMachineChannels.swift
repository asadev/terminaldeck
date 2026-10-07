import Foundation
import TerminalDeckNativeCore

/// Every channel goes to the real native coordinator/link. Browser/window and
/// file operations remain permission-scoped; absent capabilities are failures.
public enum BackendMachineChannels {
    public static let invokeChannels: Set<String> = [
        "machines:list", "machines:code", "machines:code:cancel", "machines:pair", "machines:forget", "machines:drive-windows", "machines:rename", "machines:connect", "machines:disconnect",
        "machines:attach", "machines:detach", "machines:input", "machines:resize", "machines:create", "machines:close", "machines:session:rename", "machines:upload", "machines:upload:cancel", "machines:reach", "machines:reach:close",
        "machines:controls:read", "machines:controls:apply", "machines:usage:read", "machines:account:read", "machines:account:switch", "machines:logins:read", "machines:logins:signin", "machines:logins:signout", "machines:send",
        "machines:host:read", "machines:host:restart", "machines:host:stop", "machines:github:read", "machines:github:connect", "machines:github:cancel", "machines:github:disconnect",
        "machines:ports", "machines:copilot:attach", "machines:copilot:start", "machines:copilot:refresh", "machines:copilot:say", "machines:open",
    ]
    public struct Handle: Sendable { public let channels: [String] }
    public static func register(registry: NativeChannelRegistry, coordinator: BackendMachineCoordinator,
                                localHost: BackendRemoteHostService?, ownerID: String = "native-machines",
                                authorize: @escaping @Sendable (String, NativeRPCContext) throws -> Void = { channel, context in try context.require(channel == "machines:list" ? "machines.read" : "machines.write") },
                                authorizeCall: @escaping @Sendable (String, NativeRPCContext, [NativeRPCValue]) async throws -> Void = { _, _, _ in },
                                requireReady: @escaping @Sendable () async throws -> Void = {}) async throws -> Handle {
        let local = ["machines:list", "machines:code", "machines:code:cancel", "machines:pair", "machines:forget", "machines:drive-windows", "machines:rename", "machines:connect", "machines:disconnect",
            "machines:attach", "machines:detach", "machines:input", "machines:resize", "machines:create", "machines:close", "machines:session:rename", "machines:upload", "machines:upload:cancel", "machines:reach", "machines:reach:close"]
        let requests: [String: (String, String, String)] = [
            "machines:controls:read": ("controls.read", "controls", "controls.reading"), "machines:controls:apply": ("controls.apply", "controls", "controls.applied"),
            "machines:usage:read": ("usage.read", "usage", "usage.reading"), "machines:account:read": ("account.read", "account", "account.state"),
            "machines:account:switch": ("account.switch", "account", "account.switched"), "machines:logins:read": ("logins.read", "logins", "logins.state"),
            "machines:logins:signin": ("logins.signin", "logins", "logins.signedin"), "machines:logins:signout": ("logins.signout", "logins", "logins.signedout"),
            "machines:send": ("session.send", "send", "session.sent"), "machines:host:read": ("host.status", "host.control", "host.state"),
            "machines:host:restart": ("host.restart", "host.control", "host.state"), "machines:host:stop": ("host.stop", "host.control", "host.state"),
            "machines:github:read": ("github.read", "github", "github.state"), "machines:github:connect": ("github.connect", "github", "github.state"),
            "machines:github:cancel": ("github.cancel", "github", "github.state"), "machines:github:disconnect": ("github.disconnect", "github", "github.state"),
        ]
        let oneWay: [String: (String, String)] = ["machines:ports": ("ports", "localhost"), "machines:copilot:attach": ("copilot.attach", "copilot"),
            "machines:copilot:start": ("copilot.start", "copilot"), "machines:copilot:refresh": ("copilot.state", "copilot"),
            "machines:copilot:say": ("copilot.say", "copilot"), "machines:open": ("web.open", "web")]
        let all = local + requests.keys.sorted() + oneWay.keys.sorted()
        guard Set(all) == invokeChannels, all.count == invokeChannels.count else { throw NativeRPCError(code: "machine-registration", message: "The machine channel map is incomplete or duplicated") }
        for channel in all {
            try await registry.register(channel, ownerID: ownerID, policy: { context in try authorize(channel, context) }) { context, args in
                try await requireReady()
                try await authorizeCall(channel, context, args)
                func arg(_ index: Int) -> NativeRPCValue { args.indices.contains(index) ? args[index] : .missing }
                func text(_ index: Int, _ label: String) throws -> String { try arg(index).requireString(label, nonempty: true) }
                func number(_ index: Int, _ label: String) throws -> Int { guard let value = arg(index).number, value.rounded() == value, value >= 0, value < 65536 else { throw NativeRPCError.invalidArguments("\(label) must be a bounded integer") }; return Int(value) }
                switch channel {
                case "machines:list": return try await coordinator.view()
                case "machines:code":
                    guard let localHost else { return outcome(false, "No native local host is registered for showing a pairing code.") }
                    let shown = try await localHost.showPairingCode()
                    guard shown.findable else { await localHost.cancelPairing(); return outcome(false, "This machine could not publish a pairing code on the relay.") }
                    return .object([.init("ok", .bool(true)), .init("code", .object([.init("token", .string(shown.code.token)), .init("expiresAt", .number(shown.code.expiresAt))]))])
                case "machines:code:cancel": await localHost?.cancelPairing(); return .object([.init("cancelled", .bool(true))])
                case "machines:pair":
                    guard let typed = arg(0).string else { return outcome(false, "That is not a pairing code.").setting("reason", .string("bad-code")) }  // ipc.ts:810
                    do { let record = try await coordinator.pair(code: typed); return .object([.init("ok", .bool(true)), .init("offer", .object([.init("hostId", .string(record.hostID)), .init("name", .string(record.name)), .init("platform", .string(record.platform))]))]) }
                    catch {
                        let code = (error as? NativeRPCError)?.code ?? ""  // pair.ts:56 PairFailure
                        let reason = ["pair-bad-code": "bad-code", "pair-not-found": "not-found", "pair-unreachable": "unreachable"][code] ?? "refused"
                        return outcome(false, error.localizedDescription).setting("reason", .string(reason))
                    }
                case "machines:forget": _ = try await coordinator.forget(text(0, "machine")); return try await coordinator.view()
                case "machines:drive-windows": if let allowed = arg(1).bool { _ = try await coordinator.setDrivesWindows(text(0, "machine"), allowed: allowed) }; return try await coordinator.view()
                case "machines:rename": _ = try await coordinator.rename(text(0, "machine"), name: text(1, "name")); return try await coordinator.view()
                case "machines:connect": try await coordinator.connect(text(0, "machine")); return try await coordinator.view()
                case "machines:disconnect": await coordinator.disconnect(try text(0, "machine")); return try await coordinator.view()
                case "machines:upload":
                    let path = try await coordinator.sendFile(machineID: text(0, "machine"), path: URL(fileURLWithPath: text(1, "file")), directory: arg(2).string, context: context)
                    return .object([.init("ok", .bool(true)), .init("path", .string(path))])
                case "machines:upload:cancel": return .bool(await coordinator.cancelUpload(try text(0, "machine")))
                case "machines:reach":
                    guard let machine = arg(0).string, arg(1).number != nil else { return outcome(false, "That is not a machine and a port.") }  // ipc.ts:1083
                    do { return try await coordinator.reach(machine, port: number(1, "remote port")).value } catch { return outcome(false, error.localizedDescription) }
                case "machines:reach:close":
                    guard let machine = arg(0).string, let port = arg(1).number, port.rounded() == port, port >= 0, port < 65536 else { return .bool(false) }  // ipc.ts:1107
                    await coordinator.closeReach(machine, port: Int(port)); return .bool(true)
                default: break
                }
                if let type = requests[channel]?.0, type.hasPrefix("host.") || type.hasPrefix("github.") {  // ipc.ts:1623-1663: null for a malformed or unlinked machine
                    guard let machine = arg(0).string, !machine.isEmpty, (try? await coordinator.link(machine)) != nil else { return .null }
                }
                let guest = try await coordinator.link(text(0, "machine"))
                switch channel {
                case "machines:attach": return .bool(try await guest.attach(text(1, "session"), cols: number(2, "columns"), rows: number(3, "rows")))
                case "machines:detach": try await guest.detach(text(1, "session")); return .bool(true)
                case "machines:input": try await guest.input(text(1, "session"), data: arg(2).requireString("input")); return .bool(true)
                case "machines:resize": try await guest.resize(text(1, "session"), cols: number(2, "columns"), rows: number(3, "rows")); return .bool(true)
                case "machines:create":
                    var fields: [NativeRPCValue.Field] = []
                    for (key, index) in [("cwd", 1), ("provider", 2)] { if let value = arg(index).string, !value.isEmpty { fields.append(.init(key, .string(value))) } }
                    try await guest.send(type: "create", fields: fields, capability: "create"); return .bool(true)
                case "machines:close": try await guest.send(type: "close", fields: [.init("id", .string(try text(1, "session")))], capability: "close"); return .bool(true)
                case "machines:session:rename": try await guest.send(type: "rename", fields: [.init("id", .string(try text(1, "session"))), .init("title", .string(try arg(2).requireString("title")))], capability: "rename"); return .bool(true)
                default: break
                }
                if let (type, capability, reply) = requests[channel] {
                    var fields: [NativeRPCValue.Field] = []
                    if ["controls.read", "controls.apply", "usage.read", "account.read", "account.switch", "session.send"].contains(type) { fields.append(.init("id", .string(try text(1, "session")))) }
                    if type == "controls.apply" { fields.append(.init("control", arg(2))); fields.append(.init("value", arg(3))) }
                    if type == "usage.read" { fields.append(.init("want", arg(2))); fields.append(.init("force", arg(3))) }
                    if type == "account.switch" { fields.append(.init("accountId", arg(2))) }
                    if type == "logins.signin" || type == "logins.signout" { fields.append(.init("accountId", arg(1))) }
                    if type == "session.send" { fields.append(.init("data", arg(2))) }
                    if type == "controls.read" {
                        let state = await guest.state()
                        if state.phase == .online && !state.capabilities.contains("controls") {
                            let barred = NativeRPCValue.object([.init("value", .null), .init("label", .null), .init("source", .null), .init("unavailableReason", .string("That machine's build cannot report or set a model from here. Update it to use these controls."))])
                            return .object([.init("model", barred), .init("effort", barred), .init("fast", barred), .init("permission", barred), .init("live", .bool(true)), .init("agent", .object([.init("running", .bool(false)), .init("saw", .null)])), .init("gate", .object([.init("canType", .bool(false)), .init("reason", .null)]))])
                        }
                    }
                    do {
                        let answer = try await guest.request(type: type, fields: fields, capability: capability, replies: [reply], timeoutMilliseconds: type == "usage.read" && arg(2).string == "refresh" ? 45000 : 30000)
                        if let session = fields.first(where: { $0.key == "id" })?.value, answer["id"] != session { throw NativeRPCError.malformed("That machine answered for a different session") }
                        if type == "usage.read", answer["want"] != arg(2) { throw NativeRPCError.malformed("That machine answered a different usage question") }
                        return projected(type, answer)
                    } catch {
                        if ["controls.read", "account.read", "logins.read"].contains(type) || type.hasPrefix("host.") || type.hasPrefix("github.") { return .null }
                        if type == "usage.read" { return emptyUsage(arg(2).string ?? "plan", detail: error.localizedDescription) }
                        var failure = outcome(false, "That machine did not answer, so the outcome is not known. " + error.localizedDescription)
                        if ["account.switch", "logins.signin", "logins.signout"].contains(type) { failure = failure.setting("session", .null) }
                        if type == "controls.apply" { failure = failure.setting("reading", .object([.init("value", .null), .init("label", .null), .init("source", .null)])) }
                        return failure
                    }
                }
                if let (type, capability) = oneWay[channel] {
                    let fields: [NativeRPCValue.Field] = type == "copilot.say" ? [.init("text", arg(1))] : type == "web.open" ? [.init("url", arg(1))] : []
                    if type.hasPrefix("copilot.") {
                        let state = await guest.state()
                        guard state.copilot["granted"].bool == true else { return outcome(false, "Someone on that machine must grant access to its assistant first.") }
                        do { try await guest.sendCopilot(type: type, fields: fields); return outcome(true, "Sent to that machine.") }
                        catch { return outcome(false, error.localizedDescription) }
                    }
                    try await guest.send(type: type, fields: fields, capability: capability); return .bool(true)
                }
                throw NativeRPCError(code: "missing-machine-handler", message: "The native machine channel is not registered")
            }
        }
        return Handle(channels: all)
    }
    private static func outcome(_ ok: Bool, _ message: String) -> NativeRPCValue { .object([.init("ok", .bool(ok)), .init("message", .string(message))]) }
    private static func projected(_ type: String, _ answer: NativeRPCValue) -> NativeRPCValue {
        switch type {
        case "controls.read": return answer["reading"]
        case "controls.apply": return outcome(answer["ok"].bool == true, answer["message"].string ?? "").setting("reading", answer["reading"])
        case "usage.read": return answer["answer"]["reading"] == .null ? emptyUsage(answer["want"].string ?? "plan", detail: answer["answer"]["unavailableReason"].string ?? "That machine had nothing to report.") : answer["answer"]["reading"]
        case "account.read": return .object([.init("current", answer["current"]), .init("accounts", answer["accounts"])])
        case "logins.read": return answer["accounts"]
        case "account.switch", "logins.signin", "logins.signout": return outcome(answer["ok"].bool == true, answer["message"].string ?? "").setting("session", answer["session"])
        case "session.send": return outcome(answer["ok"].bool == true, answer["message"].string ?? "")
        default: return type.hasPrefix("host.") ? answer["host"] : answer["github"]
        }
    }
    private static func emptyUsage(_ want: String, detail: String) -> NativeRPCValue {
        let now = Date().timeIntervalSince1970 * 1000
        if want == "context" {
            return .object([.init("provider", .null), .init("state", .string("not-reported")), .init("tokens", .null), .init("window", .null), .init("percent", .null), .init("windowBasis", .null), .init("model", .null), .init("modelLabel", .null), .init("source", .null), .init("reportedAt", .number(0)), .init("observedAt", .number(now)), .init("detail", .string(detail))])
        }
        let report = NativeRPCValue.object([.init("sessionId", .null), .init("readings", .array([])), .init("reason", .string(detail)), .init("account", .null), .init("assembledAt", .number(now))])
        return want == "plan" ? report : .object([.init("ok", .bool(false)), .init("outcome", .string("unwatched")), .init("detail", .string(detail)), .init("elapsedMs", .number(0)), .init("spawned", .bool(false)), .init("report", report)])
    }
}
