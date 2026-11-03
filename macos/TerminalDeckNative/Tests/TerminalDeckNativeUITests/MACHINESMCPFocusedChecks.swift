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
        let args = NativeRPCValue.object([.init("deviceId", .string("fixture-device")), .init("access", .string("look"))])
        let audit = Audit(), tools = try definitions(audit)
        try expect(Set(tools.map(\.spec.wireName)) == ["server_settings_open", "devices_pair_start", "devices_pair_allow", "devices_access_set", "devices_rename"], "All requested tools have stable wire names")
        let allow = try tool(tools, "devices.pair.allow")
        let blockedTool = try await allow.handler(context("unrelated"), args)
        let blockedTier = try await allow.handler(context(allow.spec.id, tiers: [.read]), args)
        var snapshot = await audit.snapshot()
        try expect(blockedTool.isError && blockedTier.isError && snapshot.channels.isEmpty && snapshot.owners.isEmpty, "Tool and tier grants block changes before consent or transport")

        let foreignAudit = Audit(), foreign = try tool(definitions(foreignAudit, kind: .remote), "devices.pair.allow")
        let foreignReply = try await foreign.handler(context(foreign.spec.id), args)
        snapshot = await foreignAudit.snapshot()
        try expect(foreignReply.isError && snapshot.channels.isEmpty, "A paired remote device cannot approve another device")

        let refusedAudit = Audit(); await refusedAudit.configure(refuse: true)
        let refused = try tool(definitions(refusedAudit), "devices.pair.allow")
        let refusedReply = try await refused.handler(context(refused.spec.id), args)
        snapshot = await refusedAudit.snapshot()
        try expect(refusedReply.isError && snapshot.owners == [true] && snapshot.channels.isEmpty, "Owner refusal prevents the approval operation")

        let invalidAudit = Audit(), invalid = try tool(definitions(invalidAudit), "devices.access.set")
        let invalidReply = try await invalid.handler(context(invalid.spec.id), args.setting("access", .string("owner")))
        snapshot = await invalidAudit.snapshot()
        try expect(invalidReply.isError && snapshot.channels.isEmpty && snapshot.owners.isEmpty, "Invalid access is refused before consent or transport")

        let narrowAudit = Audit(); await narrowAudit.configure(limitAccess: "look")
        let narrow = try tool(definitions(narrowAudit, kind: .key), "devices.access.set")
        let narrowReply = try await narrow.handler(context(narrow.spec.id), args.setting("access", .string("full")))
        snapshot = await narrowAudit.snapshot()
        try expect(narrowReply.isError && snapshot.owners == [true] && snapshot.channels.isEmpty, "A key cannot bypass the central narrowing refusal")

        let malformedAudit = Audit(); await malformedAudit.configure(malformedApproval: true)
        let malformed = try tool(definitions(malformedAudit), "devices.pair.allow")
        let malformedReply = try await malformed.handler(context(malformed.spec.id), args)
        snapshot = await malformedAudit.snapshot()
        try expect(malformedReply.isError && snapshot.channels == ["remote:device:approve-access"] && snapshot.summaries.isEmpty,
            "An approval reply without an approved device is refused")
        let wrongAudit = Audit(); await wrongAudit.configure(wrongApprovalAccess: true)
        let wrong = try tool(definitions(wrongAudit), "devices.pair.allow")
        let wrongReply = try await wrong.handler(context(wrong.spec.id), args)
        snapshot = await wrongAudit.snapshot()
        try expect(wrongReply.isError && snapshot.summaries.isEmpty, "Approval with a different access level is refused without a success summary")
        let missingAudit = Audit(); await missingAudit.configure(missingApprovalAccess: true)
        let missing = try tool(definitions(missingAudit), "devices.pair.allow")
        let missingReply = try await missing.handler(context(missing.spec.id), args)
        snapshot = await missingAudit.snapshot()
        try expect(missingReply.isError && snapshot.summaries.isEmpty, "Approval without a confirmed access level is refused")

        let acceptedAudit = Audit(), accepted = try tool(definitions(acceptedAudit), "devices.pair.allow")
        let acceptedReply = try await accepted.handler(context(accepted.spec.id), args)
        snapshot = await acceptedAudit.snapshot()
        try expect(!acceptedReply.isError && snapshot.channels == ["remote:device:approve-access"] && snapshot.owners == [true]
            && snapshot.summaries.count == 1, "A confirmed device approval is one consented operation")
        let accessAudit = Audit(), access = try tool(definitions(accessAudit), "devices.access.set")
        let accessReply = try await access.handler(context(access.spec.id), args)
        snapshot = await accessAudit.snapshot()
        let accessRoster = try NativeRPCValue.parseJSON(Data((accessReply.content.first?["text"].string ?? "null").utf8))
        try expect(!accessReply.isError && accessRoster.elements?.first?["access"].string == "look"
            && snapshot.channels == ["remote:device-access:set"] && snapshot.owners == [true], "A chosen access level is confirmed by the returned roster")
        // #27: the tools take every level the Devices screen offers, Work included, and Work goes through.
        let offered = BackendINT2PhoneAccessLevel.offered.map(\.rawValue)
        let enums = try ["devices.pair.allow", "devices.access.set"].map { try tool(tools, $0).spec.inputSchema["properties"]["access"]["enum"].elements?.compactMap(\.string) ?? [] }
        let workAudit = Audit(), work = try tool(definitions(workAudit), "devices.access.set")
        let workReply = try await work.handler(context(work.spec.id), args.setting("access", .string("work")))
        snapshot = await workAudit.snapshot()
        let workRoster = try NativeRPCValue.parseJSON(Data((workReply.content.first?["text"].string ?? "null").utf8))
        try expect(enums.allSatisfy { $0 == offered } && offered.contains("work") && !workReply.isError
            && workRoster.elements?.first?["access"].string == "work" && snapshot.channels == ["remote:device-access:set"],
            "Both device tools offer every level the screen offers, and Work is applied")

        let canceledAudit = Audit(), cancellation = BackendMCPCancellation()
        cancellation.cancel()
        let canceled = try tool(definitions(canceledAudit), "devices.pair.allow")
        let canceledReply = try await canceled.handler(context(canceled.spec.id, cancellation: cancellation), args)
        snapshot = await canceledAudit.snapshot()
        try expect(canceledReply.isError && snapshot.channels.isEmpty && snapshot.owners.isEmpty, "A canceled request never reaches consent or transport")

        let lateAudit = Audit(); await lateAudit.configure(cancelAtConsent: true)
        let late = try tool(definitions(lateAudit), "devices.pair.allow")
        let lateReply = try await late.handler(context(late.spec.id), args)
        snapshot = await lateAudit.snapshot()
        try expect(lateReply.isError && snapshot.owners == [true] && snapshot.channels.isEmpty, "Cancellation while waiting for consent prevents the change")

        let statusAudit = Audit(); await statusAudit.configure(cancelAtStatus: true)
        let status = try tool(definitions(statusAudit), "devices.pair.start")
        let statusReply = try await status.handler(context(status.spec.id), .object([]))
        snapshot = await statusAudit.snapshot()
        try expect(statusReply.isError && snapshot.channels == ["remote:status"] && snapshot.summaries.isEmpty,
            "Cancellation during the status read prevents a new pairing code")

        let codeAudit = Audit(), code = try tool(definitions(codeAudit), "devices.pair.start")
        let codeReply = try await code.handler(context(code.spec.id), .object([]))
        snapshot = await codeAudit.snapshot()
        let recorded = try snapshot.summaries.map { String(decoding: try $0.encodedJSON(), as: UTF8.self) }.joined()
        try expect(!codeReply.isError && codeReply.structuredContent?["token"].string == "fixture-one-use-secret"
            && snapshot.channels == ["remote:status", "remote:pair"] && snapshot.owners == [true]
            && !recorded.contains("fixture-one-use-secret"), "One-use code is returned after consent and stays out of action summaries")

        let openAudit = Audit(), open = try tool(definitions(openAudit), "server.settings.open")
        let openReply = try await open.handler(context(open.spec.id, tiers: [.read]), .object([.init("serverId", .string("fixture-server"))]))
        snapshot = await openAudit.snapshot()
        try expect(!openReply.isError && snapshot.owners == [false] && snapshot.opened == ["fixture-server"]
            && snapshot.channels == ["servers:list"], "Opening settings reads the local roster without a server connection")
        return count
    }
}
