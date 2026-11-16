import Foundation
@testable import TerminalDeckBackend
import TerminalDeckNativeCore
#if !MACHINES_TOOL_TESTS
@testable import TerminalDeckNative
#endif

/// Exercises the real additive tool definitions with local fakes, never a registry or backend.
@MainActor
enum MACHINESMCPFocusedChecks {
    static func failure(_ message: String) -> NSError {
        NSError(domain: "MACHINESMCPFocusedChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    actor Audit {
        var channels: [String] = []
        var ownerFlags: [Bool] = []
        var summaries: [NativeRPCValue] = []
        var opened: [String] = []
        var refuse = false
        var cancelAtConsent = false
        var limitAccess: String?
        var malformedApproval = false
        var cancelAtStatus = false
        var wrongApprovalAccess = false
        var missingApprovalAccess = false

        func configure(refuse: Bool = false, cancelAtConsent: Bool = false, limitAccess: String? = nil,
                       malformedApproval: Bool = false, cancelAtStatus: Bool = false,
                       wrongApprovalAccess: Bool = false, missingApprovalAccess: Bool = false) {
            self.refuse = refuse; self.cancelAtConsent = cancelAtConsent
            self.limitAccess = limitAccess; self.malformedApproval = malformedApproval
            self.cancelAtStatus = cancelAtStatus
            self.wrongApprovalAccess = wrongApprovalAccess; self.missingApprovalAccess = missingApprovalAccess
        }
        func authorize(_ context: BackendMCPCallContext, args: NativeRPCValue, owner: Bool) throws {
            ownerFlags.append(owner)
            if cancelAtConsent { context.cancellation.cancel() }
            if refuse { throw NativeRPCError(code: "denied", message: "The owner said no.") }
            if let limitAccess, args["access"].string != limitAccess {
                throw NativeRPCError(code: "not-granted", message: "This key may only narrow access.")
            }
        }
        func invoke(_ channel: String, arguments: [NativeRPCValue], context: BackendMCPCallContext) -> NativeRPCValue {
            channels.append(channel)
            if channel == "servers:list" {
                return .array([.object([.init("id", .string("fixture-server")), .init("name", .string("Fixture server")),
                    .init("address", .string("example.invalid")), .init("username", .string("admin"))])])
            }
            if channel == "remote:status" {
                if cancelAtStatus { context.cancellation.cancel() }
                return .object([.init("running", .bool(true))])
            }
            if channel == "remote:pair" { return .object([.init("token", .string("fixture-one-use-secret"))]) }
            if channel == "remote:device:approve-access", malformedApproval { return .object([.init("ok", .bool(true))]) }
            if channel == "remote:device-access:set" {
                return .array([.object([.init("id", .string("fixture-device")),
                    .init("access", arguments.count > 1 ? arguments[1] : .null)])])
            }
            let selected = arguments.count > 1 ? arguments[1] : .null
            return .array([.object([.init("id", .string("fixture-device")), .init("status", .string("approved")),
                .init("access", missingApprovalAccess ? .missing : wrongApprovalAccess ? .string("full") : selected)])])
        }
        func record(_ summary: NativeRPCValue) { summaries.append(summary) }
        func open(_ id: String) { opened.append(id) }
        func snapshot() -> (channels: [String], owners: [Bool], summaries: [NativeRPCValue], opened: [String]) {
            (channels, ownerFlags, summaries, opened)
        }
    }

    static func definitions(_ audit: Audit, kind: BackendDeckToolsAppCaller.Kind = .local) throws -> [BackendDeckToolsDefinition] {
        let access = BackendDeckToolsAppAccess(caller: { _ in .init(kind: kind) }, knownFolder: { _, path in path },
            session: { _, _ in .null }, runnableProject: { _, path in path },
            rpc: { _ in .init(caller: .nativeApp, ownerID: "machines-fixture") },
            authorize: { context, _, args, _, _, owner in try await audit.authorize(context, args: args, owner: owner) },
            record: { _, _, _, summary in await audit.record(summary) })
        return try MACHINESMCP.definitions(access: access, invoke: { channel, arguments, context in
            await audit.invoke(channel, arguments: arguments, context: context)
        }, openServer: { server in await audit.open(server.id) })
    }
    static func context(_ tool: String, tiers: Set<BackendMCPTier> = [.read, .act, .alter],
                        cancellation: BackendMCPCancellation = .init()) -> BackendMCPCallContext {
        .init(sessionID: "machines-fixture", machineID: "", projectRoot: nil, attended: true,
            allowedTools: [tool], allowedTiers: tiers, cancellation: cancellation)
    }
    static func run() async throws -> Int {
        var count = 0
        func expect(_ condition: Bool, _ message: String) throws {
            guard condition else { throw failure(message) }
            count += 1; print("PASS MACHINES MCP: \(message)")
        }
        func tool(_ definitions: [BackendDeckToolsDefinition], _ id: String) throws -> BackendDeckToolsDefinition {
            guard let result = definitions.first(where: { $0.spec.id == id }) else { throw failure("Missing tool \(id)") }
            return result
        }
        let audit = Audit(), tools = try definitions(audit)
        // Owner, 13 Nov: the old device tools (a code, letting a waiting device in, access levels) are gone; the
        // Devices window's own tools are devices_page and devices_remove (DevicesPageToolsTests).
        try expect(Set(tools.map(\.spec.wireName)) == ["server_settings_open"], "Only the server settings tool is left here")
        var snapshot = await audit.snapshot()
        try expect(snapshot.channels.isEmpty, "Listing the tools calls nothing")
        let openAudit = Audit(), open = try tool(definitions(openAudit), "server.settings.open")
        let openReply = try await open.handler(context(open.spec.id, tiers: [.read]), .object([.init("serverId", .string("fixture-server"))]))
        snapshot = await openAudit.snapshot()
        try expect(!openReply.isError && snapshot.owners == [false] && snapshot.opened == ["fixture-server"]
            && snapshot.channels == ["servers:list"], "Opening settings reads the local roster without a server connection")
        return count
    }
}
