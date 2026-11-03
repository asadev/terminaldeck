import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Standalone Swift Testing conversion of the eight Hoot XCTest draft cases.
/// All dependencies remain in-memory stubs: no runtime, account, file or AI calls.
struct ROUTINESHootChecks {
    private actor Fixture {
        var value = NativeRPCValue.string("ask")
        var mutations = 0
        var resets = 0
        var authorizations: [Bool] = []
        var visibleCalls = 0
        var deny = false
        func read() -> NativeRPCValue { value }
        func apply(_ next: NativeRPCValue) { value = next; mutations += 1 }
        func reset() { resets += 1 }
        func visible() { visibleCalls += 1 }
        func counts() -> (Int, Int, [Bool], Int) { (mutations, resets, authorizations, visibleCalls) }
        func authorize(_ mustAnswer: Bool) throws {
            authorizations.append(mustAnswer)
            if deny { throw NativeRPCError(code: "not-permitted", message: "The person said no.") }
        }
        func setDenied() { deny = true }
    }
    private func owner(_ fixture: Fixture) -> BackendROUTINESHootSettings {
        // The one policy field left after the "What Hoot may do" switches were retired (Asad, 12 Oct).
        BackendROUTINESHootSettings(.init(fields: ["permissionMode": .init(read: { await fixture.read() }, apply: { await fixture.apply($0) })],
            reset: { await fixture.reset() }))
    }
    private func access(_ fixture: Fixture, hoot: Bool = false) -> BackendDeckToolsAppAccess {
        .init(caller: { _ in .init(kind: .session, sessionID: hoot ? "@hoot" : "fixture") },
            knownFolder: { _, folder in folder }, session: { _, _ in .object([]) }, runnableProject: { _, folder in folder },
            rpc: { _ in .init(caller: .internalEngine, ownerID: "fixture") },
            authorize: { _, _, _, _, _, mustAnswer in try await fixture.authorize(mustAnswer) },
            record: { _, _, _, _ in })
    }
    private func context(_ definitions: [BackendDeckToolsDefinition], tiers: Set<BackendMCPTier> = [.read, .act, .alter]) -> BackendMCPCallContext {
        .init(sessionID: "fixture", machineID: "", projectRoot: nil, attended: true,
            allowedTools: Set(definitions.map { $0.spec.id }), allowedTiers: tiers, cancellation: .init())
    }
    @Test func absentBackingNeverClaimsAWorkingCapability() async throws {
        let service = BackendROUTINESHootSettings(.init())
        let result = try await service.read()
        for key in BackendROUTINESHootSettings.policyFields + ["reset"] { #expect(result["capabilities"][key] == .bool(false)) }
        do {
            _ = try await service.set(field: "permissionMode", value: .string("plan"))
            Issue.record("Unsupported control saved")
        } catch let error as NativeRPCError {
            #expect(error.code == "unavailable")
        } catch { Issue.record("Unexpected error: \(error)") }
        // The retired switches are refused with the new rule: Hoot can always do these.
        for retired in BackendROUTINESHootSettings.retiredFields {
            do {
                _ = try await service.set(field: retired, value: .bool(false))
                Issue.record("A retired switch was saved")
            } catch { #expect(error.localizedDescription.contains("Hoot can always")) }
        }
    }
    @Test func realFieldCallbackIsAppliedAndReread() async throws {
        let fixture = Fixture(), service = owner(fixture)
        let result = try await service.set(field: "permissionMode", value: .string("plan"))
        #expect(result["permissionMode"] == .string("plan"))
        #expect(result["capabilities"]["permissionMode"] == .bool(true))
        let count = await fixture.counts()
        #expect(count.0 == 1)
    }
    @Test func invalidFieldValuesCannotReachTheirOwners() async throws {
        let fixture = Fixture(), service = owner(fixture)
        for pair in [("runSessions", NativeRPCValue.string("true")), ("permissionMode", .string("bypass")),
                     ("routingMode", .string("silent")), ("folders", .array([.string("relative")])),
                     ("folders", .array([.string("/a"), .string("/a")])), ("unknown", .bool(true))] {
            do {
                _ = try await service.set(field: pair.0, value: pair.1)
                Issue.record("Invalid input accepted")
            } catch { }
        }
        let count = await fixture.counts()
        #expect(count.0 == 0)
    }
    @Test func resetNeedsExactNameAndRunsOnlyItsInjectedOwner() async throws {
        let fixture = Fixture(), service = owner(fixture)
        do {
            _ = try await service.reset(confirmation: "yes")
            Issue.record("Reset without exact name")
        } catch { }
        let before = await fixture.counts()
        #expect(before.1 == 0)
        let result = try await service.reset(confirmation: "Reset Hoot")
        #expect(result["ok"] == .bool(true))
        let after = await fixture.counts()
        #expect(after.1 == 1)
        #expect(after.0 == 0)
    }
    @Test func channelRequiresGenuineSettingsWindow() async throws {
        let fixture = Fixture(), service = owner(fixture), registry = NativeChannelRegistry()
        try await service.register(registry: registry, requireWindow: { context in
            guard context.ownerID == "settings-fixture" else { throw NativeRPCError(code: "access-denied", message: "Not the Settings window.") }
        })
        do {
            _ = try await registry.invoke("hoot:settings:set", context: .init(caller: .nativeApp, ownerID: "foreign-window"),
                arguments: [.object([.init("field", .string("permissionMode")), .init("value", .string("plan"))])])
            Issue.record("Caller tag became authority")
        } catch { }
        let count = await fixture.counts()
        #expect(count.0 == 0)
    }
    @Test func mcpReadsAreFreeAndChangesRequireThePerson() async throws {
        let fixture = Fixture(), service = owner(fixture)
        let definitions = try BackendROUTINESHootMCP.definitions(service: service, access: access(fixture),
            visible: { _ in await fixture.visible() }, isHootSession: { $0 == "@hoot" })
        let caller = context(definitions)
        let read = try #require(definitions.first { $0.spec.wireName == "hoot_settings_get" })
        _ = try await read.handler(caller, .object([]))
        let change = try #require(definitions.first { $0.spec.wireName == "hoot_settings_set" })
        _ = try await change.handler(caller, .object([.init("field", .string("permissionMode")), .init("value", .string("plan"))]))
        let result = await fixture.counts()
        #expect(result.2 == [false, true])
        #expect(result.0 == 1)
        #expect(result.3 >= 6)
    }
    @Test func deniedMCPChangeCannotReachTheOwner() async throws {
        let fixture = Fixture()
        await fixture.setDenied()
        let definitions = try BackendROUTINESHootMCP.definitions(service: owner(fixture), access: access(fixture),
            visible: { _ in }, isHootSession: { _ in false })
        let change = try #require(definitions.first { $0.spec.wireName == "hoot_settings_set" })
        do {
            _ = try await change.handler(context(definitions), .object([.init("field", .string("permissionMode")), .init("value", .string("plan"))]))
            Issue.record("Denied change ran")
        } catch { }
        let result = await fixture.counts()
        #expect(result.0 == 0)
    }
    @Test func hootCannotGrantItselfAbilities() async throws {
        let fixture = Fixture()
        let definitions = try BackendROUTINESHootMCP.definitions(service: owner(fixture), access: access(fixture, hoot: true),
            visible: { _ in }, isHootSession: { $0 == "@hoot" })
        let change = try #require(definitions.first { $0.spec.wireName == "hoot_settings_set" })
        do {
            _ = try await change.handler(context(definitions), .object([.init("field", .string("permissionMode")), .init("value", .string("plan"))]))
            Issue.record("Hoot changed its own policy")
        } catch { }
        let result = await fixture.counts()
        #expect(result.0 == 0)
        #expect(result.2.isEmpty)
    }
}
