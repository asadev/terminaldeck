import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Server grants cannot cross callers or facts")
struct BackendServersGrantScopePortTests {
    private var local: BackendServersCaller { .init(kind: .local, attended: true, context: .init(caller: .internalEngine, ownerID: "local-copilot")) }
    private var remote: BackendServersCaller { .init(kind: .remote, attended: true, context: .init(caller: .pairedDevice, ownerID: "phone-1")) }
    private func args(server: String = "s1", card: String = "service:mine.service", action: String = "restart") -> NativeRPCValue { .object([.init("serverId", .string(server)), .init("cardId", .string(card)), .init("action", .string(action))]) }
    @Test func startsWithNothingGranted() { let g = BackendServersGrants(assistantName: "Hoot"); #expect(!g.granted("s1", asker: "local") && g.state("s1") == nil && g.list() == []) }
    @Test func grantDoesNotSpreadToSecondServer() throws { let g = BackendServersGrants(assistantName: "Hoot"); _ = try g.grant("s1", asker: "local"); #expect(g.granted("s1", asker: "local") && !g.granted("s2", asker: "local")) }
    @Test func expiryBoundaryAndPageStateAgree() throws {
        let clock = BackendServersIPCPortClock(), g = BackendServersGrants(assistantName: "Hoot", now: { clock.now }); _ = try g.grant("s1", asker: "local"); clock.advance(BackendServersGrants.defaultGrantMilliseconds - 1); #expect(g.granted("s1", asker: "local")); clock.advance(2); #expect(!g.granted("s1", asker: "local") && g.state("s1") == nil)
    }
    @Test func durationCannotExceedCeiling() throws { let g = BackendServersGrants(assistantName: "Hoot", now: { 0 }); #expect(try g.grant("s1", asker: "local", forMilliseconds: 30 * 24 * 60 * 60 * 1000).expiresAt == BackendServersGrants.maximumGrantMilliseconds) }
    @Test func unknownServerGrantRefusesAndNeverExists() { let g = BackendServersGrants(assistantName: "Hoot", knows: { $0 == "s1" }); #expect(throws: BackendServersGrantRefused.self) { try g.grant("made-up", asker: "local") }; #expect(!g.granted("made-up", asker: "local")) }
    @Test func guestCannotReceiveOrRideLocalGrant() throws {
        let g = BackendServersGrants(assistantName: "Hoot"); #expect(throws: BackendServersGrantRefused.self) { try g.grant("s1", asker: "remote") }; #expect(!g.granted("s1", asker: "remote")); _ = try g.grant("s1", asker: "local"); #expect(g.granted("s1", asker: "local") && !g.granted("s1", asker: "remote"))
    }
    @Test func guestToolRefusesBeforeDialogOrActEvenWithLocalGrant() async throws {
        let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; _ = try await a.room.grants.grant("s1", asker: "local")
        do { _ = try await BackendServersTools.invoke("servers.control", arguments: args(), caller: remote, room: a.room); Issue.record("Remote control accepted") } catch { #expect(error.localizedDescription.localizedCaseInsensitiveContains("only works for the person at this machine")) }
        #expect(await a.audit.tiers() == [] && a.client.commands == []); #expect(await !a.room.grants.granted("s1", asker: remote.grantAsker)); await a.stop()
    }
    @Test func ungrantedControlUsesAlter() async throws {
        let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; _ = try await a.room.look("s1", caller: a.caller)
        _ = try await BackendServersTools.invoke("servers.control", arguments: args(), caller: local, room: a.room); #expect(await a.audit.tiers() == [.alter]); await a.stop()
    }
    @Test func onlyGrantedServerDropsToAct() async throws {
        let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; _ = try a.store.add(.init(name: "two", address: "second.test", username: "root")); a.credentials.holdForSession("new-1", credential: .password("second-only")); _ = try await a.room.grants.grant("s1", asker: "local")
        _ = try await a.room.look("s1", caller: a.caller); _ = try await BackendServersTools.invoke("servers.control", arguments: args(), caller: local, room: a.room)
        _ = try await a.room.look("new-1", caller: a.caller); _ = try await BackendServersTools.invoke("servers.control", arguments: args(server: "new-1"), caller: local, room: a.room); #expect(await a.audit.tiers() == [.act, .alter]); await a.stop()
    }
    @Test func expiryRestoresAlterConsent() async throws {
        let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; _ = try await a.room.grants.grant("s1", asker: "local"); _ = try await a.room.look("s1", caller: a.caller); _ = try await BackendServersTools.invoke("servers.control", arguments: args(), caller: local, room: a.room)
        a.clock.advance(BackendServersGrants.defaultGrantMilliseconds + 1); _ = try await a.room.look("s1", caller: a.caller); _ = try await BackendServersTools.invoke("servers.control", arguments: args(), caller: local, room: a.room); #expect(await a.audit.tiers() == [.act, .alter]); await a.stop()
    }
    @Test func noNamedServerCannotReachAct() async throws {
        let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; _ = try await a.room.grants.grant("s1", asker: "local")
        do { _ = try await BackendServersTools.invoke("servers.control", arguments: .object([]), caller: local, room: a.room); Issue.record("Unnamed server accepted") } catch { #expect(error.localizedDescription.contains("serverId is required")) }; #expect(await a.audit.tiers() == []); await a.stop()
    }
    @Test func unseenServerRefusesWithLookInstructionBeforeConsent() async throws {
        let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }
        do { _ = try await BackendServersTools.invoke("servers.control", arguments: args(card: "service:td-scratch.service"), caller: local, room: a.room); Issue.record("Unseen server accepted") } catch { #expect(error.localizedDescription.contains("Call servers.look")) }; #expect(await a.audit.tiers() == [] && a.client.commands == []); await a.stop()
    }
    @Test func unsupportedCardFactsRefuseBeforeAction() async throws {
        let raw = "init=sysvinit\nroot=no\ncontainers=\n#services ok\none.service\t+\t+\t\n#adminunits ok\none.service\n#end ok", a = try BackendServersIPCPortFixture(raw: raw); defer { a.cleanup() }; _ = try await a.room.look("s1", caller: a.caller)
        do { _ = try await BackendServersTools.invoke("servers.control", arguments: args(card: "service:one.service"), caller: local, room: a.room); Issue.record("Unsupported card accepted") } catch { #expect(error.localizedDescription.contains("can’t tell how this server starts and stops things")) }; #expect(await a.audit.tiers() == [] && a.client.commands == []); await a.stop()
    }
    @Test func accessKeyCanControlButNeverRidesCopilotGrant() async throws {
        let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; _ = try await a.room.grants.grant("s1", asker: "local"); _ = try await a.room.look("s1", caller: a.caller)
        _ = try await BackendServersTools.invoke("servers.control", arguments: args(), caller: local, room: a.room)
        _ = try await a.room.look("s1", caller: a.caller)
        let key = BackendServersCaller(kind: .key, attended: true, context: .init(caller: .internalEngine, ownerID: "ChatGPT-key"))
        _ = try await BackendServersTools.invoke("servers.control", arguments: args(), caller: key, room: a.room); #expect(await a.audit.tiers() == [.act, .alter])
        do { _ = try await BackendServersTools.invoke("servers.control", arguments: args(), caller: remote, room: a.room); Issue.record("Paired device accepted") } catch { #expect(error.localizedDescription.localizedCaseInsensitiveContains("only works for the person")) }; await a.stop()
    }
}
