import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Routine registration ownership and event regressions")
struct BackendRoutinesFoundationParityRegistrationRoutineTests {
    private let tools: Set<String> = ["routines.list", "routines.get", "routines.save", "routines.delete", "routines.run", "routines.pause", "routines.resume"]
    private let channels: Set<String> = ["routines:list", "routines:get", "routines:create", "routines:update", "routines:delete", "routines:run", "routines:pause", "routines:resume", "routines:text", "routines:save-text"]
    @Test func missingMCPPairRefusesBeforeAnyChannelOrLease() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesFoundationParityRegistrationRoutineRig.make(), registry = NativeChannelRegistry(), server = BackendNativeMCPServer(), probe = BackendRoutinesFoundationParityRegistrationProbe()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        for serverOnly in [true, false] {
            #expect(await routinesTaskErrorCode {
                _ = try await BackendRoutinesRegistration.register(registry: registry, service: r.service, events: probe.routineBindings(),
                    mcpServer: serverOnly ? server : nil, mcpAccess: serverOnly ? nil : probe.access())
            } == "unavailable")
            #expect(await registry.channels().isEmpty); #expect(await server.registrations().isEmpty); #expect(await probe.installed.isEmpty)
        }
        }
    }
    @Test func statusAndExitRequireAuthoritativeMetadataSubscription() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesFoundationParityRegistrationRoutineRig.make(), registry = NativeChannelRegistry(), probe = BackendRoutinesFoundationParityRegistrationProbe()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        for exitOnly in [true, false] {
            let subscribeStatus: BackendRoutinesEventBindings.Status = { @Sendable callback in await probe.subscribeStatus(callback) }
            let subscribeExit: BackendRoutinesEventBindings.Exit = { @Sendable callback in await probe.subscribeExit(callback) }
            let statusBinding: BackendRoutinesEventBindings.Status? = exitOnly ? nil : subscribeStatus
            let exitBinding: BackendRoutinesEventBindings.Exit? = exitOnly ? subscribeExit : nil
            let bindings = BackendRoutinesEventBindings(sessionStatus: statusBinding, sessionExit: exitBinding)
            let error = await routinesTaskError { _ = try await BackendRoutinesRegistration.register(registry: registry, service: r.service, events: bindings) }
            #expect(error == "Routine session status/exit subscriptions need the authoritative session-start metadata subscription first, so folder scope and routine provenance are preserved.")
            #expect(await registry.channels().isEmpty); #expect(await probe.installed.isEmpty)
        }
        }
    }
    @Test func duplicateChannelPreflightPreservesOtherOwnerAndHealth() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesFoundationParityRegistrationRoutineRig.make(wired: ["alert"]), registry = NativeChannelRegistry(), server = BackendNativeMCPServer(), probe = BackendRoutinesFoundationParityRegistrationProbe()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        try await registry.register("routines:list", ownerID: "other") { _, _ in .string("other channel") }
        try await server.registerTool(registrationTestTool(id: "other.tool", wire: "other_tool"), ownerID: "other") { _, _ in .value(.string("other tool")) }
        #expect(await routinesTaskErrorCode { _ = try await BackendRoutinesRegistration.register(registry: registry, service: r.service, events: probe.routineBindings(), mcpServer: server, mcpAccess: probe.access()) } == "duplicate-handler")
        #expect(try await registry.invoke("routines:list", context: .init(caller: .nativeApp, ownerID: "test"), arguments: []) == .string("other channel"))
        #expect(await registry.channels() == ["routines:list"]); #expect(await server.registrations().map { $0.0.id } == ["other.tool"])
        #expect(await probe.installed.isEmpty); #expect(try await r.sources()["alert"]?.subscribed == true)
        }
    }
    @Test func duplicateWireAliasPreflightPreservesToolsAndRoutes() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesFoundationParityRegistrationRoutineRig.make(), registry = NativeChannelRegistry(), server = BackendNativeMCPServer(), probe = BackendRoutinesFoundationParityRegistrationProbe()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        try await registry.register("unrelated:route", ownerID: "other") { _, _ in .string("kept") }
        try await server.registerTool(registrationTestTool(id: "other.routine", wire: "routines_list"), ownerID: "other") { _, _ in .value(.string("kept")) }
        #expect(await routinesTaskErrorCode { _ = try await BackendRoutinesRegistration.register(registry: registry, service: r.service, events: probe.routineBindings(), mcpServer: server, mcpAccess: probe.access()) } == "duplicate-tool")
        #expect(await registry.channels() == ["unrelated:route"]); #expect(await server.registrations().map { $0.0.id } == ["other.routine"]); #expect(await probe.installed.isEmpty)
        }
    }
    @Test func exactSevenToolsAndTenChannelsUseSuppliedConsentAndLogging() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesFoundationParityRegistrationRoutineRig.make(), registry = NativeChannelRegistry(), server = BackendNativeMCPServer(), probe = BackendRoutinesFoundationParityRegistrationProbe()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        let handle = try await BackendRoutinesRegistration.register(registry: registry, service: r.service, ownerID: "root", mcpServer: server, mcpAccess: probe.access())
        #expect(handle.channels == channels); #expect(Set(await registry.channels()) == channels); #expect(handle.toolIDs == tools)
        #expect(Set(await server.registrations().map { $0.0.id }) == tools); #expect(handle.catalogueMetadata.count == 7)
        #expect(!handle.toolIDs.contains("routines.text")); #expect(!handle.toolIDs.contains("routines.save-text")); #expect(!handle.toolIDs.contains("routines.save_text"))
        #expect(handle.mcpOwnerID != nil && handle.mcpOwnerID != "root"); #expect(!handle.startedEngine)
        let list = try #require(await server.registrations().first { $0.0.id == "routines.list" })
        await probe.setDeny(true); let denied = try await list.1(registrationTestContext(), .object([]))
        #expect(denied.isError); #expect(denied.structuredContent?["code"].string == "registration-test-denied")
        #expect(await probe.authorized == ["routines.list"]); #expect(await probe.recorded.isEmpty)
        await probe.setDeny(false); #expect(try await !list.1(registrationTestContext(), .object([])).isError)
        #expect(await probe.authorized == ["routines.list", "routines.list"]); #expect(await probe.recorded == ["routines.list"])
        await handle.cleanup.cancelAndWait()
        }
    }
    @Test func declaredWiredSourcesAreNotTreatedAsReturnedEventLeases() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesFoundationParityRegistrationRoutineRig.make(wired: ["session-finished", "session-failed", "session-idle", "alert"]), registry = NativeChannelRegistry()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        let handle = try await BackendRoutinesRegistration.register(registry: registry, service: r.service)
        #expect(handle.boundSources.isEmpty); #expect(!handle.sessionMetadataBound); #expect(!handle.wakeBound); #expect(!handle.startedEngine)
        for (kind, source) in try await r.sources() {
            #expect(!source.subscribed); #expect(source.note == "No native \(kind) event subscription was supplied to routine registration.")
        }
        await handle.cleanup.cancelAndWait()
        }
    }
    @Test func returnedLeasesSetHonestHealthAndScopedCancellationStopsStaleCallbacks() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesFoundationParityRegistrationRoutineRig.make(), registry = NativeChannelRegistry(), server = BackendNativeMCPServer(), probe = BackendRoutinesFoundationParityRegistrationProbe()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        // Same root owner, different area: cleanup must not erase either.
        try await registry.register("unrelated:route", ownerID: "root") { _, _ in .string("kept") }
        try await server.registerTool(registrationTestTool(id: "other.tool", wire: "other_tool"), ownerID: "root") { _, _ in .value(.string("kept")) }
        let handle = try await BackendRoutinesRegistration.register(registry: registry, service: r.service, ownerID: "root", events: probe.routineBindings(), mcpServer: server, mcpAccess: probe.access())
        #expect(handle.boundSources == ["session-finished", "session-failed", "session-idle", "alert"]); #expect(handle.sessionMetadataBound); #expect(handle.wakeBound); #expect(!handle.startedEngine)
        #expect(try await r.sources().values.allSatisfy(\.subscribed))
        await probe.emitRoutineEvents(); let before = try await r.sources()
        #expect(before["session-idle"]?.events == 1); #expect(before["session-failed"]?.events == 1); #expect(before["session-finished"]?.events == 0); #expect(before["alert"]?.events == 1)
        await handle.cleanup.cancelAndWait(); await handle.cleanup.cancelAndWait()
        #expect(await probe.detached == ["wake", "alerts", "exit", "status", "started"])
        await probe.emitRoutineEvents(stale: true); let after = try await r.sources()
        for kind in handle.boundSources { #expect(after[kind]?.events == before[kind]?.events); #expect(after[kind]?.subscribed == false); #expect(after[kind]?.note == "The native routine event registration was removed.") }
        #expect(await registry.channels() == ["unrelated:route"]); #expect(await server.registrations().map { $0.0.id } == ["other.tool"])
        #expect(try await registry.invoke("unrelated:route", context: .init(caller: .nativeApp, ownerID: "test"), arguments: []) == .string("kept"))
        }
    }
    @Test func failedSubscriptionRollsBackOnlyAcquiredLeasesChannelsAndTools() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesFoundationParityRegistrationRoutineRig.make(), registry = NativeChannelRegistry(), server = BackendNativeMCPServer(), probe = BackendRoutinesFoundationParityRegistrationProbe()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        try await registry.register("unrelated:route", ownerID: "other") { _, _ in .bool(true) }
        try await server.registerTool(registrationTestTool(id: "other.tool", wire: "other_tool"), ownerID: "other") { _, _ in .value(.bool(true)) }
        let events = BackendRoutinesEventBindings(sessionStarted: { await probe.subscribeStarted($0) }, sessionStatus: { _ in throw NativeRPCError(code: "binding-failed", message: "Status owner unavailable.") })
        #expect(await routinesTaskErrorCode { _ = try await BackendRoutinesRegistration.register(registry: registry, service: r.service, events: events, mcpServer: server, mcpAccess: probe.access()) } == "binding-failed")
        #expect(await probe.installed == ["started"]); #expect(await probe.detached == ["started"])
        #expect(await registry.channels() == ["unrelated:route"]); #expect(await server.registrations().map { $0.0.id } == ["other.tool"])
        for source in try await r.sources().values { #expect(!source.subscribed); #expect(source.note == "The native routine event registration was rolled back.") }
        }
    }
}

@Suite("CRM registration suppliers, envelopes and ownership regressions")
struct BackendRoutinesFoundationParityRegistrationCRMTests {
    private func register(_ r: BackendRoutinesTaskStoreParityRig, registry: NativeChannelRegistry, probe: BackendRoutinesFoundationParityRegistrationProbe,
                          ownership: BackendCrmRegistration.DetailOwnership = .ownsDetailChannel,
                          functions: Set<String> = ["addTaskSubtask"]) async throws -> BackendCrmRegistration.Contribution {
        try await BackendCrmRegistration.register(registry: registry, ownerID: "crm-area", configuration: r.config, detailOwnership: ownership,
            state: { await probe.state() }, subscribeChanges: { await probe.subscribeChanged($0) },
            installSuppliers: { await probe.installation($0, functions: functions) }, problem: { _ in })
    }
    @Test func suppliersSendExactEventsWithoutReadingStateAndUseKnownPeopleAndRules() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(memory: true), registry = NativeChannelRegistry(), probe = BackendRoutinesFoundationParityRegistrationProbe()
        defer { try? FileManager.default.removeItem(at: r.root) }
        let events = try await registry.subscribeAll(ownerID: "ui") { await probe.receive($0) }
        let contribution = try await register(r, registry: registry, probe: probe)
        #expect(contribution.eventChannels == ["tasks:changed", "tasks:open"]); #expect(contribution.ownedChannels == ["tasks:local-detail"]); #expect(contribution.mcpToolIDs.isEmpty)
        await probe.emitChanged(); try await contribution.suppliers.openTask("local:task")
        #expect(await probe.received == [routinesTaskObject([("channel", .string("tasks:changed")), ("args", .array([]))]), routinesTaskObject([("channel", .string("tasks:open")), ("args", .array([.string("local:task")]))])])
        #expect(await probe.stateReads == 0); #expect(try await contribution.suppliers.state()["marker"].string == "real supplied state"); #expect(await probe.stateReads == 1)
        #expect(await routinesTaskError { try await contribution.suppliers.openTask("") } == "Choose the task to open.")
        let people = contribution.suppliers.people
        #expect(try await people.known("me")); #expect(try await people.known("hoot")); #expect(try await people.known("builder")); #expect(try await !people.known("ghost"))
        #expect(try await people.named("me")["name"].string == "You"); #expect(try await people.named("hoot")["name"].string == "Hoot"); #expect(try await people.named("builder")["name"].string == "Builder")
        #expect(Set(try await contribution.suppliers.localPeople().map(\.id)) == ["me", "hoot", "builder", "tester"])
        #expect(await routinesTaskError { _ = try await people.named("ghost") } == "That task person no longer exists.")
        try await r.config.removeAgent("builder"); #expect(try await !people.known("builder"))
        let rules = contribution.suppliers.rules
        #expect(try rules.normaliseFieldLabel(.string("  Budget  ")).get() == "Budget")
        #expect(try rules.computeFormula("2+3", []).get() == 5); #expect(rules.normalizeLabels([.string(" tag "), .string("tag"), .string("")]) == ["tag"])
        let rule = try #require(rules.normalizeRoutine(.object(["frequency": .string("weekly")]), nil))
        #expect(rules.serializeRoutine(rule).object?["frequency"]?.string == "weekly")
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        #expect(rules.localInstantAt("2026-10-07", 9, 30, utc.timeZone) == utc.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 9, minute: 30)))
        await contribution.lease.cancelAndWait(); await probe.emitChanged()
        #expect(await probe.received.count == 2); #expect(await probe.detached == ["changed", "suppliers"])
        await events.cancelAndWait()
        }
    }
    @Test func nativeOnlyDetailChecksWhitelistArgsAndActualImplementedSubset() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(memory: true), registry = NativeChannelRegistry(), probe = BackendRoutinesFoundationParityRegistrationProbe()
        defer { try? FileManager.default.removeItem(at: r.root) }
        let contribution = try await register(r, registry: registry, probe: probe)
        let own = NativeRPCContext(caller: .nativeApp, ownerID: "ui")
        let args: [NativeRPCValue] = [.string("local:a"), .string("Write it")]
        #expect(try await registry.invoke("tasks:local-detail", context: own, arguments: [.string("addTaskSubtask"), .array(args)]) == routinesTaskObject([("function", .string("addTaskSubtask")), ("args", .array(args)), ("by", .string("me"))]))
        let callers: [NativeRPCContext.Caller] = [.page, .pairedDevice, .internalEngine]
        for caller in callers {
            let stranger = NativeRPCContext(caller: caller, ownerID: "stranger")
            #expect(await routinesTaskErrorCode { _ = try await registry.invoke("tasks:local-detail", context: stranger, arguments: [.string("addTaskSubtask"), .array(args)]) } == "access-denied")
        }
        for (input, error) in [
            ([NativeRPCValue.string("dropDatabase"), .array([])], "That is not something the task popup can do."),
            ([.string("addTaskSubtask"), .string("bad arguments")], "That request was not understood."),
            ([.string("listTaskComments"), .array([.string("local:a")])], "The native task popup function listTaskComments is unavailable.")
        ] { #expect(try await registry.invoke("tasks:local-detail", context: own, arguments: input) == routinesTaskObject([("ok", .bool(false)), ("error", .string(error))])) }
        #expect(await probe.dispatched.count == 1); #expect(contribution.implementedFunctions == ["addTaskSubtask"])
        await contribution.lease.cancelAndWait()
        }
    }
    @Test func delegatedDetailRequiresExplicitReceiptAndCleanupKeepsTaskOwnerRoute() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(memory: true), registry = NativeChannelRegistry(), probe = BackendRoutinesFoundationParityRegistrationProbe()
        defer { try? FileManager.default.removeItem(at: r.root) }
        try await registry.register("tasks:local-detail", ownerID: "tasks-owner") { _, _ in .string("task-owner handler") }
        try await registry.register("unrelated:route", ownerID: "crm-area") { _, _ in .string("kept") }
        let ownership = BackendCrmRegistration.DetailOwnership.alreadyOwnedByTasks(expectedOwnerID: "tasks-owner") { actual, channel, owner in
            #expect(actual === registry); #expect(channel == "tasks:local-detail"); #expect(owner == "tasks-owner"); await probe.verify(channel, owner)
        }
        let contribution = try await register(r, registry: registry, probe: probe, ownership: ownership)
        #expect(contribution.ownedChannels.isEmpty); #expect(await probe.verified == [.array([.string("tasks:local-detail"), .string("tasks-owner")])])
        await contribution.lease.cancelAndWait()
        #expect(Set(await registry.channels()) == ["tasks:local-detail", "unrelated:route"])
        #expect(try await registry.invoke("tasks:local-detail", context: .init(caller: .nativeApp, ownerID: "ui"), arguments: []) == .string("task-owner handler"))
        #expect(await probe.detached == ["changed", "suppliers"])
        }
    }
    @Test func presenceAloneNeverBypassesDelegatedOwnershipVerification() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(memory: true), registry = NativeChannelRegistry(), probe = BackendRoutinesFoundationParityRegistrationProbe()
        defer { try? FileManager.default.removeItem(at: r.root) }
        try await registry.register("tasks:local-detail", ownerID: "stranger") { _, _ in .string("kept") }
        let ownership = BackendCrmRegistration.DetailOwnership.alreadyOwnedByTasks(expectedOwnerID: "tasks-owner") { _, _, _ in throw NativeRPCError(code: "wrong-owner", message: "Authoritative receipt names another owner.") }
        #expect(await routinesTaskErrorCode { _ = try await register(r, registry: registry, probe: probe, ownership: ownership) } == "wrong-owner")
        #expect(await registry.channels() == ["tasks:local-detail"]); #expect(await probe.installed == ["suppliers"]); #expect(await probe.detached == ["suppliers"])
        }
    }
    @Test func missingDelegatedRouteRollsBackReturnedSupplierLease() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(memory: true), registry = NativeChannelRegistry(), probe = BackendRoutinesFoundationParityRegistrationProbe()
        defer { try? FileManager.default.removeItem(at: r.root) }
        let ownership = BackendCrmRegistration.DetailOwnership.alreadyOwnedByTasks(expectedOwnerID: "tasks-owner") { _, _, _ in }
        #expect(await routinesTaskErrorCode { _ = try await register(r, registry: registry, probe: probe, ownership: ownership) } == "missing-handler")
        #expect(await registry.channels().isEmpty); #expect(await probe.detached == ["suppliers"])
        }
    }
    @Test func emptyOrInventedSupportedSetsRefuseAndReleaseInstallation() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(memory: true); defer { try? FileManager.default.removeItem(at: r.root) }
        let sets: [Set<String>] = [[], ["dropDatabase"]]
        for functions in sets {
            let registry = NativeChannelRegistry(), probe = BackendRoutinesFoundationParityRegistrationProbe()
            #expect(await routinesTaskErrorCode { _ = try await register(r, registry: registry, probe: probe, functions: functions) } == "invalid-arguments")
            #expect(await registry.channels().isEmpty); #expect(await probe.detached == ["suppliers"]); #expect(await probe.installed == ["suppliers"])
        }
        }
    }
    @Test func duplicateDetailPreservesExistingOwnerAndRollsBackSuppliers() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(memory: true), registry = NativeChannelRegistry(), probe = BackendRoutinesFoundationParityRegistrationProbe()
        defer { try? FileManager.default.removeItem(at: r.root) }
        try await registry.register("tasks:local-detail", ownerID: "other") { _, _ in .string("kept") }
        #expect(await routinesTaskErrorCode { _ = try await register(r, registry: registry, probe: probe) } == "duplicate-handler")
        #expect(try await registry.invoke("tasks:local-detail", context: .init(caller: .nativeApp, ownerID: "ui"), arguments: []) == .string("kept"))
        #expect(await probe.detached == ["suppliers"]); #expect(await probe.installed == ["suppliers"])
        }
    }
    @Test func failedChangeSubscriptionRemovesOwnDetailAndSupplierLease() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(memory: true), registry = NativeChannelRegistry(), probe = BackendRoutinesFoundationParityRegistrationProbe()
        defer { try? FileManager.default.removeItem(at: r.root) }
        try await registry.register("unrelated:route", ownerID: "other") { _, _ in .bool(true) }
        #expect(await routinesTaskErrorCode {
            _ = try await BackendCrmRegistration.register(registry: registry, ownerID: "crm-area", configuration: r.config, detailOwnership: .ownsDetailChannel,
                state: { .object([]) }, subscribeChanges: { _ in throw NativeRPCError(code: "subscribe-failed", message: "Actual change owner unavailable.") },
                installSuppliers: { await probe.installation($0) }, problem: { _ in })
        } == "subscribe-failed")
        #expect(await registry.channels() == ["unrelated:route"]); #expect(await probe.detached == ["suppliers"])
        }
    }
    @Test func serviceDispatcherIncludesFieldsRecurrenceAndExtrasAsWellAsBaseFunctions() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(memory: true); defer { try? FileManager.default.removeItem(at: r.root) }
        let dispatcher = BackendCrmRegistration.DetailDispatcher(service: r.detail)
        #expect(BackendTaskDetailService.functions.isSubset(of: dispatcher.implementedFunctions))
        #expect(BackendTaskDetailService.fieldFunctions.isSubset(of: dispatcher.implementedFunctions))
        #expect(BackendTaskDetailService.recurrenceFunctions.isSubset(of: dispatcher.implementedFunctions))
        #expect(BackendTaskDetailService.extraFunctions.isSubset(of: dispatcher.implementedFunctions))
        for function in ["listTaskFields", "fetchRoutine", "uploadTaskFile", "addTaskSubtask"] { #expect(dispatcher.implementedFunctions.contains(function)) }
        #expect(dispatcher.implementedFunctions.isSubset(of: Set(BackendCrmDetailContract.functions))); #expect(!dispatcher.implementedFunctions.contains("dropDatabase"))
        }
    }
}
