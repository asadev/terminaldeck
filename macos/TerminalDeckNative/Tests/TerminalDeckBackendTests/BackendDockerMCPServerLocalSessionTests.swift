import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor BackendDockerMCPServerSessionChannels: BackendDeckToolsMachinesChannels {
    private var calls: [String] = []
    func call(_ channel: String, _ arguments: [NativeRPCValue], context: BackendDeckToolsMachinesContext) async throws -> NativeRPCValue {
        calls.append(channel)
        return .array([])
    }
    func recorded() -> [String] { calls }
}
private struct BackendDockerMCPServerSessionShells: BackendDeckToolsMachinesServerShells {
    func openShells() async throws -> [NativeRPCValue] { [] }
    func shellScreen(_ shellID: String) async throws -> String? { nil }
}
private actor BackendDockerMCPServerSessionRPC {
    private var owners: [String] = []
    func record(_ context: NativeRPCContext) {
        owners.append(context.ownerID)
    }
    func recorded() -> [String] { owners }
}

@Suite("Local session server access preserves provenance and consent tiers")
struct BackendDockerMCPServerLocalSessionTests {
    private func context(kind: BackendDeckToolsMachinesContext.Kind = .session, machine: String = "", paired: Bool = false) -> BackendDeckToolsMachinesContext {
        .init(kind: kind, attended: true, sessionID: "local-session", machineID: machine,
              rpc: .init(caller: paired ? .pairedDevice : .page, ownerID: "authenticated-session"),
              startedByCopilot: { _ in false }, noteStarted: { _ in })
    }
    private func tool(_ id: String, tier: BackendMCPTier) throws -> BackendMCPTool {
        try .init(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: "Fixture server policy",
                  inputSchema: .object([.init("type", .string("object"))]), tier: tier)
    }
    private func servers(_ channels: BackendDockerMCPServerSessionChannels, enabled: Bool) -> BackendDeckToolsMachinesServers {
        .init(channels: channels, shells: BackendDockerMCPServerSessionShells(),
              dataRoot: URL(fileURLWithPath: "/fixture/data"), home: URL(fileURLWithPath: "/fixture/home"), serverAccessEnabled: enabled)
    }

    @Test func trustedNilAndEmptyMachineSessionsGainOnlyServerOwnership() {
        for machine in [Optional<String>.none, .some("")] {
            let caller = BackendServersCaller(kind: .session, attended: true,
                context: .init(caller: .internalEngine, ownerID: "authenticated-session"), machineID: machine, serverAccessEnabled: true)
            #expect(caller.actsAsOwner)
            #expect(caller.grantAsker == "session")
        }
        #expect(!context().actsAsOwner, "Shared nonserver Machines ownership must stay unchanged")
    }

    @Test func pairedAndRemoteMachineSessionsRemainRefusedEvenWithFeatureEnabled() {
        for (machine, paired) in [(Optional("remote-machine"), false), (Optional(" "), false), (nil, true)] {
            let caller = BackendServersCaller(kind: .session, attended: true,
                context: .init(caller: paired ? .pairedDevice : .internalEngine, ownerID: "authenticated-session"),
                machineID: machine, serverAccessEnabled: true)
            #expect(!caller.actsAsOwner)
        }
        let remote = BackendServersCaller(kind: .remote, attended: true,
            context: .init(caller: .pairedDevice, ownerID: "phone"), machineID: nil, serverAccessEnabled: true)
        #expect(!remote.actsAsOwner)
    }

    @Test func featureOffRetainsLegacySessionRefusal() {
        let caller = BackendServersCaller(kind: .session, attended: true,
            context: .init(caller: .internalEngine, ownerID: "authenticated-session"), machineID: nil, serverAccessEnabled: false)
        #expect(!caller.actsAsOwner)
    }

    @Test func credentialInputStillRequiresTrustedInternalMarker() {
        let marked = BackendServersCaller(kind: .session, attended: true,
            context: .init(caller: .internalEngine, ownerID: "authenticated-session", capabilities: ["servers:credential-input"]),
            machineID: nil, serverAccessEnabled: true)
        // DKA2: even a marked local session never consumes typed credentials;
        // sessions add servers from SSH settings, which needs none.
        #expect(!marked.canConsumeCredentialInput)
        #expect(marked.actsAsOwner)
        let unmarked = BackendServersCaller(kind: .session, attended: true,
            context: .init(caller: .internalEngine, ownerID: "authenticated-session"), machineID: nil, serverAccessEnabled: true)
        #expect(!unmarked.canConsumeCredentialInput)
        let remote = BackendServersCaller(kind: .session, attended: true,
            context: .init(caller: .internalEngine, ownerID: "remote-session", capabilities: ["servers:credential-input"]),
            machineID: "remote-machine", serverAccessEnabled: true)
        #expect(!remote.canConsumeCredentialInput)
    }

    @Test func localSessionServerPoliciesKeepReadAndAlterTiers() async throws {
        let channels = BackendDockerMCPServerSessionChannels(), service = servers(channels, enabled: true)
        let read = try await service.policy(tool("servers.details", tier: .read), .object([.init("about", .string("keys"))]), context())
        #expect(read.tier == .read)
        let shell = try await service.policy(tool("servers.shell", tier: .alter), .object([.init("do", .string("open")), .init("serverId", .string("s1"))]), context())
        #expect(shell.tier == .alter)
        let add = try await service.policy(tool("servers.manage", tier: .alter), .object([
            .init("do", .string("add")), .init("address", .string("fixture.invalid")),
            .init("username", .string("fixture")), .init("keyPath", .string("/fixture/keys/example"))
        ]), context())
        #expect(add.tier == .alter)
        #expect(!context().actsAsOwner)
        #expect(await channels.recorded() == [], "Policy must not read key bytes or run a server command")
    }

    @Test func serverPoliciesRejectRemoteSessionAndKeepNonserverHereOnlyFence() async throws {
        let channels = BackendDockerMCPServerSessionChannels()
        for (caller, enabled) in [(context(machine: "remote-machine"), true), (context(paired: true), true), (context(), false)] {
            do { _ = try await servers(channels, enabled: enabled).policy(tool("servers.details", tier: .read), .object([.init("about", .string("keys"))]), caller); Issue.record("Server policy accepted an untrusted/disabled session") }
            catch { }
        }
        do { try BackendDeckToolsMachinesShared.hereOnly(context(), "A nonserver machine action"); Issue.record("Shared Machines owner fence was broadened") }
        catch { }
        #expect(await channels.recorded() == [])
    }

    @Test func localSessionCannotRideHootStandingGrantToLowerControlTier() async throws {
        let fixture = try BackendServersIPCPortFixture(enforceKeyScope: true)
        defer { fixture.cleanup() }
        let grants = await fixture.room.grants
        _ = try grants.grant("s1", asker: "local")
        _ = try await fixture.room.look("s1", caller: fixture.caller)
        let session = BackendServersCaller(kind: .session, attended: true,
            context: .init(caller: .internalEngine, ownerID: "authenticated-session"), machineID: nil, serverAccessEnabled: true)
        _ = try await BackendServersTools.invoke("servers.control", arguments: .object([
            .init("serverId", .string("s1")), .init("cardId", .string("service:mine.service")), .init("action", .string("restart"))
        ]), caller: session, room: fixture.room)
        #expect(await fixture.audit.tiers() == [.alter])
        #expect(!grants.granted("s1", asker: session.grantAsker))
        await fixture.stop()
    }
}
