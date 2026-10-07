import Foundation
import TerminalDeckNativeCore

/// One composition entry point for shared/crm. That source directory owns
/// pure rules and the task-popup contract, not an additional MCP catalogue.
/// BackendTaskMCP retains ownership of tasks.* and crm.task tools.
public enum BackendCrmRegistration {
    public enum DetailOwnership: Sendable {
        /// The root must make BackendTaskChannels skip tasks:local-detail.
        /// Duplicate registration fails; this registrar never replaces it.
        case ownsDetailChannel
        /// The verifier must use the root's authoritative registration record
        /// (the successful BackendTaskChannels.register result, its actual
        /// owner ID and registry identity). registry.has alone is not proof.
        case alreadyOwnedByTasks(expectedOwnerID: String,
            verifyOwnership: @Sendable (NativeChannelRegistry, String, String) async throws -> Void)
    }

    /// Closure form supports the existing service and a future task-owner
    /// implementation without claiming all 78 source functions are available.
    public struct DetailDispatcher: Sendable {
        public let implementedFunctions: Set<String>
        public let call: @Sendable (String, [NativeRPCValue], String) async throws -> NativeRPCValue
        public init(service: BackendTaskDetailService) {
            implementedFunctions = BackendTaskDetailService.functions.union(BackendTaskDetailService.fieldFunctions).union(BackendTaskDetailService.recurrenceFunctions).union(BackendTaskDetailService.extraFunctions)
            call = { function, arguments, by in await service.call(function, arguments: arguments, by: by) }
        }
        public init(implementedFunctions: Set<String>, call: @escaping @Sendable (String, [NativeRPCValue], String) async throws -> NativeRPCValue) {
            self.implementedFunctions = implementedFunctions; self.call = call
        }
    }

    /// These operations share the earlier CRM rule implementations and Core
    /// models. Receivers may retain this value when constructing the task owner;
    /// NativeChannelRegistry has no generic supplier slots.
    public struct Rules: Sendable {
        public let normaliseFieldLabel: @Sendable (CrmValue?) -> FieldRes<String> = { BackendCrmFields.normaliseFieldLabel($0) }
        public let normaliseFieldConfig: @Sendable (FieldKind, CrmValue?, [TaskField]?) -> FieldRes<FieldConfig> = {
            BackendCrmFields.normaliseConfig($0, $1, siblings: $2)
        }
        public let normaliseFieldValue: @Sendable (FieldKind, FieldConfig, CrmValue, ValueCtx) -> FieldRes<CrmValue> = {
            BackendCrmFields.normaliseValue($0, $1, $2, ctx: $3)
        }
        public let reconcileFieldValue: @Sendable (FieldKind, FieldConfig, CrmValue) -> CrmValue = { BackendCrmFields.reconcileValue($0, $1, $2) }
        public let parseFormula: @Sendable (String) -> FieldRes<FormulaAst> = { BackendCrmFields.parseFormula($0) }
        public let computeFormula: @Sendable (String?, [TaskField]) -> FieldRes<Double> = { BackendCrmFields.computeFormula($0, fields: $1) }
        public let rowToField: @Sendable (CrmValue) -> TaskField? = { BackendCrmFields.rowToField($0) }
        public let normalizeRoutine: @Sendable (CrmValue?, String?) -> RoutineRule? = { BackendCrmRoutineRules.normalizeRoutine($0, legacy: $1) }
        public let routineRefusal: @Sendable (CrmValue, String) -> String? = { BackendCrmRoutineRules.routineRefusal($0, today: $1) }
        public let serializeRoutine: @Sendable (RoutineRule) -> CrmValue = { BackendCrmRoutineRules.serializeRoutine($0) }
        public let dueScheduleDates: @Sendable (String, String, RoutineRule, Date, Int, TimeZone) -> BackendCrmRoutineRules.DueScheduleDates = {
            BackendCrmRoutineRules.dueScheduleDates(anchor: $0, last: $1, rule: $2, now: $3, datesSoFar: $4, zone: $5)
        }
        public let nextDateOnDone: @Sendable (RoutineRule, String, String?, String?, String, [String]) -> String = {
            BackendCrmRoutineRules.nextDateOnDone($0, anchor: $1, occurrence: $2, due: $3, today: $4, own: $5)
        }
        public let nextOccurrenceDates: @Sendable (String?, String?, String, String, String?, TimeZone) -> (startDate: String?, dueDate: String) = {
            BackendCrmRecurrence.nextOccurrenceDates(startDate: $0, dueDate: $1, rule: $2, today: $3, from: $4, zone: $5)
        }
        public let localInstantAt: @Sendable (String, Int, Int, TimeZone) -> Date? = { BackendCrmTime.localInstantAt($0, $1, $2, zone: $3) }
        public let normalizeLabels: @Sendable ([CrmValue]) -> [String] = { BackendCrmTaskPage.normalizeLabels($0) }
        public let normalizeRecurrenceRule: @Sendable (CrmValue?) -> CrmValue = { BackendCrmTaskPage.normalizeRecurrenceRule($0) }
        public let checkUpload: @Sendable (String, Double) -> BackendCrmTaskRules.UploadCheck = { BackendCrmTaskRules.checkUpload(name: $0, size: $1) }
        public let parseAttachmentHref: @Sendable (String) throws -> (taskId: String, attachmentId: String)? = { try BackendCrmAttachmentRules.parseTaskAttachmentHref($0) }
        public let isCommentPending: @Sendable (CommentMeta?, Date, TimeZone) -> Bool = { BackendCrmComments.isPending($0, now: $1, zone: $2) }
        public let visibleComment: @Sendable (String?, CommentMeta?, String, Date, TimeZone) -> Bool = {
            BackendCrmComments.visibleTo(authorUserID: $0, meta: $1, viewerID: $2, now: $3, zone: $4)
        }
        public let spliceInlineStorage: @Sendable (String, Int, Int, String) -> BackendCrmInlineFiles.Edit = {
            BackendCrmInlineFiles.spliceStorage($0, start: $1, end: $2, insert: $3)
        }
        public let visibleTitleLength: @Sendable (String) -> Int = { BackendCrmInlineFiles.visibleLength($0) }
    }

    public struct Suppliers: Sendable {
        /// Reads the same live configuration used by the task service.
        public let people: BackendTaskDetailPeople
        public let localPeople: @Sendable () async throws -> [CrmPerson]
        public let rules: Rules
        /// Actual TasksState read supplied by the root (e.g. view.state()).
        public let state: @Sendable () async throws -> NativeRPCValue
        /// Source envelopes: tasks:changed [] and tasks:open [taskID]. The
        /// changed callback does not read state or introduce a polling loop.
        public let changed: @Sendable () async throws -> Void
        public let openTask: @Sendable (String) async throws -> Void
    }

    public struct TaskOwnerInstallation: Sendable {
        public let dispatcher: DetailDispatcher
        /// Must detach the bindings installed by the factory. In delegated
        /// mode it must not remove TaskChannels registrations it does not own.
        public let supplierLease: NativeRPCSubscription
        public init(dispatcher: DetailDispatcher, supplierLease: NativeRPCSubscription) {
            self.dispatcher = dispatcher; self.supplierLease = supplierLease
        }
    }

    public struct Contribution: Sendable {
        public let suppliers: Suppliers
        public let dispatcher: DetailDispatcher
        public let ownedChannels: [String]
        public let eventChannels: [String]
        public let contractFunctions: [String]
        public let implementedFunctions: Set<String>
        public let mcpToolIDs: [String]
        /// Retain for the graph's lifetime; cancelAndWait() detaches the change
        /// listener, installed suppliers and only this registrar's own channel.
        public let lease: NativeRPCSubscription
    }

    public typealias SupplierInstaller = @Sendable (Suppliers) async throws -> TaskOwnerInstallation
    public typealias ChangeSubscriber = @Sendable (@escaping @Sendable () async -> Void) async throws -> NativeRPCSubscription

    /// Construct the task-detail owner through installSuppliers so it receives
    /// its immutable people/rule dependencies before being used. The factory
    /// must undo its own partial installation if it throws before returning a
    /// lease. Start services only after the complete root registration succeeds.
    /// subscribeChanges attaches to real config/store/engine change callbacks;
    /// no additional schedule, state reader, MCP tool or event name is invented.
    /// ownerID must be unique to this contribution's registration lifetime.
    public static func register(registry: NativeChannelRegistry, ownerID: String, configuration: BackendTaskConfiguration,
                                detailOwnership: DetailOwnership,
                                state: @escaping @Sendable () async throws -> NativeRPCValue,
                                subscribeChanges: @escaping ChangeSubscriber,
                                installSuppliers: @escaping SupplierInstaller,
                                problem: @escaping @Sendable (NativeRPCError) async -> Void) async throws -> Contribution {
        guard !ownerID.isEmpty else { throw NativeRPCError.invalidArguments("A CRM contribution needs its own owner ID.") }
        if case .alreadyOwnedByTasks(let expected, _) = detailOwnership, expected.isEmpty {
            throw NativeRPCError.invalidArguments("The task-detail registration needs the known task owner ID.")
        }
        try Task.checkCancellation()
        let localPeople: @Sendable () async throws -> [CrmPerson] = {
            let rows = try await configuration.allAgents()
            let agents = try rows.map { row -> (id: String, name: String) in
                guard let id = row["id"].string, let name = row["name"].string, !id.isEmpty else {
                    throw NativeRPCError.malformed("A configured task agent has no valid ID or name.")
                }
                return (id, name)
            }
            return BackendCrmPeople.localPeople(agents)
        }
        let people = BackendTaskDetailPeople(named: { id in
            if id == BackendCrmDetailContract.meID { return BackendCrmWire.person(BackendCrmPeople.localPerson(id, "You")) }
            if id == BackendCrmDetailContract.hootID { return BackendCrmWire.person(BackendCrmPeople.localPerson(id, "Hoot")) }
            guard let person = try await localPeople().first(where: { $0.id == id }) else {
                throw NativeRPCError.invalidArguments("That task person no longer exists.")
            }
            return BackendCrmWire.person(person)
        }, known: { id in
            if id == BackendCrmDetailContract.meID || id == BackendCrmDetailContract.hootID { return true }
            return try await localPeople().contains(where: { $0.id == id })
        })
        let changed: @Sendable () async throws -> Void = { try await registry.publish("tasks:changed", arguments: []) }
        let openTask: @Sendable (String) async throws -> Void = { id in
            guard !id.isEmpty else { throw NativeRPCError.invalidArguments("Choose the task to open.") }
            try await registry.publish("tasks:open", arguments: [.string(id)])
        }
        let suppliers = Suppliers(people: people, localPeople: localPeople, rules: Rules(), state: state, changed: changed, openTask: openTask)
        let installation = try await installSuppliers(suppliers)
        var ownedDetail = false
        var changeLease: NativeRPCSubscription?
        let detailChannel = BackendCrmDetailContract.channel
        do {
            try Task.checkCancellation()
            let contract = Set(BackendCrmDetailContract.functions)
            guard !installation.dispatcher.implementedFunctions.isEmpty,
                  installation.dispatcher.implementedFunctions.isSubset(of: contract) else {
                throw NativeRPCError.invalidArguments("The supplied task-detail dispatcher must name its actual supported CRM popup functions.")
            }
            switch detailOwnership {
            case .ownsDetailChannel:
                let dispatcher = installation.dispatcher
                try await registry.register(detailChannel, ownerID: ownerID, policy: { context in
                    guard context.caller == .nativeApp else {
                        throw NativeRPCError(code: "access-denied", message: "tasks: only the app’s own window may change task settings")
                    }
                }) { context, arguments in
                    guard let function = context.argument(0, in: arguments).string, BackendCrmDetailContract.isLocalDetailFn(function) else {
                        return .object([.init("ok", .bool(false)), .init("error", .string("That is not something the task popup can do."))])
                    }
                    guard let values = context.argument(1, in: arguments).elements else {
                        return .object([.init("ok", .bool(false)), .init("error", .string("That request was not understood."))])
                    }
                    guard dispatcher.implementedFunctions.contains(function) else {
                        return .object([.init("ok", .bool(false)), .init("error", .string("The native task popup function \(function) is unavailable."))])
                    }
                    do { return try await dispatcher.call(function, values, BackendCrmDetailContract.meID) }
                    catch { return .object([.init("ok", .bool(false)), .init("error", .string(error.localizedDescription))]) }
                }
                ownedDetail = true
            case .alreadyOwnedByTasks(let expectedOwnerID, let verifyOwnership):
                // The root's receipt verifies identity/owner; presence is only
                // the additional liveness check, never a substitute for proof.
                try await verifyOwnership(registry, detailChannel, expectedOwnerID)
                guard await registry.has(detailChannel) else {
                    throw NativeRPCError(code: "missing-handler", message: "The task owner has not registered tasks:local-detail.")
                }
            }
            changeLease = try await subscribeChanges {
                do { try await changed() }
                catch { await problem(NativeRPCError.wrapping(error)) }
            }
            try Task.checkCancellation()
            let ownedChannels = ownedDetail ? [detailChannel] : []
            let acquiredChangeLease = changeLease!
            let supplierLease = installation.supplierLease
            let lease = NativeRPCSubscription {
                await acquiredChangeLease.cancelAndWait()
                await supplierLease.cancelAndWait()
                for channel in ownedChannels { await registry.removeHandler(channel, ownerID: ownerID) }
            }
            return Contribution(suppliers: suppliers, dispatcher: installation.dispatcher, ownedChannels: ownedChannels,
                eventChannels: ["tasks:changed", "tasks:open"], contractFunctions: BackendCrmDetailContract.functions,
                implementedFunctions: installation.dispatcher.implementedFunctions, mcpToolIDs: [], lease: lease)
        } catch {
            await changeLease?.cancelAndWait()
            await installation.supplierLease.cancelAndWait()
            if ownedDetail { await registry.removeHandler(detailChannel, ownerID: ownerID) }
            throw error
        }
    }
}
