import Foundation
import TerminalDeckNativeCore

/// Lane A2, lean first version: what lane A's wiring is handed for the two rows (projects I11, agents I10), and the
/// ONE read-only tool. Two Macs changing the same thing: per field the newest wins (the merge core as built), the
/// other value is kept and carried; there is no screen for choosing in this version, only this list, so lane A's
/// page can show "N earlier versions kept". No tool here approves, chooses or changes anything.
public actor BackendCloudLeanTools {
    public static let toolID = "cloud.versions"
    public static let inventoryRows = ["I10", "I11"]
    private static let schema = CloudValue(.object([.init("type", .string("object")), .init("additionalProperties", .bool(false)),
        .init("properties", .object([.init("row", .object([.init("type", .string("string")),
            .init("enum", .array([.string(BackendCloudLeanAgents.domain), .string(BackendCloudLeanProjects.domain)]))]))]))]))
    /// Handed to lane A; nothing in lane A2 registers it. Rows stay off in the app until the integrator proved them.
    public static let contribution = CloudFeatureContribution(owner: "A2", tools: [
        .init(id: toolID, title: "Cloud: earlier versions kept",
              description: "Lists, for projects and agents, how many earlier versions are kept after two Macs changed the same thing, what is waiting on this Mac, and what changed here from other devices. Read only: it changes and approves nothing.",
              inputSchema: schema, mutates: false, inventoryRows: inventoryRows)],
        inventoryRows: inventoryRows, actions: [])
    static let fromAnotherDevice = "from another device"

    private let adapters: [CloudBrainRecordAdapter]
    public init(adapters: [CloudBrainRecordAdapter]) { self.adapters = adapters }

    /// "N earlier versions kept", for lane A's page.
    public static func keptSentence(_ count: Int) -> String {
        switch count {
        case 0: return "No earlier versions kept."
        case 1: return "1 earlier version kept."
        default: return "\(count) earlier versions kept."
        }
    }
    /// The two numbers lane A's page shows without reading the list.
    public func counts() async throws -> (kept: Int, waiting: Int) {
        var kept = 0, waiting = 0
        for adapter in adapters {
            let listing = try await adapter.listing()
            kept += listing.keptCount; waiting += listing.waiting.count
        }
        return (kept, waiting)
    }
    /// The read-only tool. A value that came from another device is never in the answer, except the one-line names,
    /// models and efforts already applied here, each marked "from another device" (design v2 S6).
    public func invoke(_ tool: String, arguments: CloudValue) async throws -> CloudValue {
        guard tool == Self.toolID, let fields = arguments.raw.fields, Set(fields.map { $0.key }).isSubset(of: ["row"]),
              Set(fields.map { $0.key }).count == fields.count else { throw CloudFailure.invalidRequest }
        let wanted = arguments.raw["row"].string
        if arguments.raw.has("row"), wanted != BackendCloudLeanAgents.domain, wanted != BackendCloudLeanProjects.domain { throw CloudFailure.invalidRequest }
        var keptCount = 0
        var kept: [NativeRPCValue] = [], waiting: [NativeRPCValue] = [], changes: [NativeRPCValue] = [], gaps: [NativeRPCValue] = [], notes: [NativeRPCValue] = [], mentions: [NativeRPCValue] = []
        for adapter in adapters where wanted == nil || wanted == adapter.domain {
            let listing = try await adapter.listing()
            let row = NativeRPCValue.string(adapter.domain)
            keptCount += listing.keptCount
            for item in listing.kept {
                var entry: [NativeRPCValue.Field] = [.init("row", row), .init("record", .string(item.record)), .init("field", .string(item.field)),
                    .init("time", .number(Double(item.time))), .init("keptFrom", .string(item.mine ? "this Mac" : Self.fromAnotherDevice))]
                if !item.mine { entry.append(.init("device", .string(item.device))) }
                if let preview = item.preview { entry.append(.init("preview", .string(preview))) }
                kept.append(.object(entry))
            }
            for item in listing.waiting {
                waiting.append(.object([.init("row", row), .init("record", .string(item.record)), .init("field", .string(item.field)),
                    .init("reason", .string(item.reason))]))
            }
            for item in listing.changes {
                var entry: [NativeRPCValue.Field] = [.init("row", row), .init("record", .string(item.record)), .init("field", .string(item.field)),
                    .init("device", .string(item.device)), .init("time", .number(Double(item.time))), .init("origin", .string(Self.fromAnotherDevice))]
                if let from = item.from { entry.append(.init("from", .string(from))) }
                if let to = item.to { entry.append(.init("to", .string(to))) }
                changes.append(.object(entry))
            }
            for gap in listing.gaps { gaps.append(.object([.init("row", row), .init("reason", .string(gap))])) }
            for note in listing.notes { notes.append(.object([.init("row", row), .init("text", .string(note))])) }
            for line in listing.mentions { mentions.append(.object([.init("row", row), .init("text", .string(line))])) }
        }
        return CloudValue(.object([.init("keptCount", .number(Double(keptCount))), .init("sentence", .string(Self.keptSentence(keptCount))),
            .init("kept", .array(kept)), .init("waitingCount", .number(Double(waiting.count))), .init("waiting", .array(waiting)),
            .init("changes", .array(changes)), .init("gaps", .array(gaps)), .init("mentions", .array(mentions)), .init("notOnOtherMacs", .array(notes)),
            .init("note", .string("Read only. Values set on another device are not shown here; choosing between versions is not in this version."))]))
    }
}

/// Everything lane A's wiring needs for the two rows of one signed-in account, built in one call. It REGISTERS
/// NOTHING: no adapter joins the sync core, no tool exists and no file is written until lane A calls
/// `activation.start(outbox:)` and registers `BackendCloudLeanTools.contribution` itself. With neither row switched
/// on, nothing is built at all. Exact steps: macos/night/codex/cloud-adapters-wiring.md.
public struct BackendCloudLeanRecords: Sendable {
    /// Inventory rows of this lane in the lean first version: agents with their instruction files, the project list.
    public static let agentsRow = BackendCloudLeanAgents.inventoryRow
    public static let projectsRow = BackendCloudLeanProjects.inventoryRow
    public static let rows: Set<String> = [agentsRow, projectsRow]
    /// The display-only signal after an import (review should-fix 4): screens redraw on it; no engine listens to it.
    public static let displayEvent = "cloud-records:shown"
    /// The domains the sync core must admit for the switched-on rows (made through `CloudWire.domain`).
    public static func domains(_ enabledRows: Set<String>) throws -> Set<String> {
        var domains: Set<String> = []
        if enabledRows.contains(agentsRow) { domains.insert(try CloudWire.domain(BackendCloudLeanAgents.domain)) }
        if enabledRows.contains(projectsRow) { domains.insert(try CloudWire.domain(BackendCloudLeanProjects.domain)) }
        return domains
    }

    public let projects: BackendCloudLeanProjects?
    public let agents: BackendCloudLeanAgents?
    public let adapters: [CloudBrainRecordAdapter]
    public let activation: CloudBrainRecordActivation
    public let tools: BackendCloudLeanTools
    public let store: CloudBrainAgentsStore

    /// - `cloudFolder`: the app's own Cloud folder in its data folder (lane A's `NativeCloudLaunch.folder(dataRoot)`).
    /// - `subjectHash`, `deviceId`: the signed-in account and this Mac's registered device, as the sync store has them.
    /// - `serviceTime`: the sync core's clock (`{ engine.serviceTime() }`).
    /// - `registry`, `roster`: the app's one project registry and one task configuration (a row without its owner is not built).
    /// - `defaultProvider`: this Mac's default AI, as the launcher reads it.
    /// - `projectsChanged`, `agentsChanged`: refresh the two screens after an import. DISPLAY ONLY: publish
    ///   `displayEvent`, which only the project list and the Agents page listen to. Never the task change hub and never
    ///   the app-wide "tasks:changed" channel (other parts of the app re-read answers, outcomes and hires on it).
    /// - `placeMemory`: asks lane A's memory to place what waited for a project (after the person chose a folder).
    /// - `recordsApplied` (MAC-NEXT-7): after project or agent records from Cloud were applied here; lane A tries the
    ///   memory rows it set aside again at once (they may have waited for exactly that record). Starts no work.
    /// - `firstArrivalConfirmed`: true once the person confirmed, in this Mac's own window, the devices this Mac takes
    ///   changes from (lane A's new-Mac sheet, or a Trust press). Only then does an agent new to this Mac arrive with
    ///   its project and seat; the default (false) keeps them waiting. Answer NIL while the trusted list cannot be read
    ///   (never false for "unreadable"): a new agent then waits and is decided again when the list reads.
    /// - `fullAccess` (Y2, 13 Nov): true while this Mac's device-trust setting is "Automatically, with my account" (the
    ///   default). Changes to projects and agents from the account's own trusted devices are then applied in full with
    ///   no click, including those held earlier (released at the next capture pass); false ("Ask me for each new
    ///   device") keeps them held and listed. The default here is false, the strict way, for callers that do not say.
    /// - `folders` (14 Nov): project folders on this Mac; a project with no folder here gets one by itself.
    /// Returns nil when neither row is switched on.
    public static func make(enabledRows: Set<String>, cloudFolder: URL, subjectHash: String, deviceId: String, serviceTime: @escaping @Sendable () -> Int64?,
                            registry: BackendPROJRegistry?, roster: BackendTaskConfiguration?,
                            defaultProvider: @escaping @Sendable () async -> String = { "claude" },
                            projectsChanged: @escaping @Sendable () async -> Void = {}, agentsChanged: @escaping @Sendable () async -> Void = {},
                            placeMemory: @escaping @Sendable () async -> Void = {},
                            recordsApplied: @escaping @Sendable () async -> Void = {},
                            firstArrivalConfirmed: @escaping @Sendable () async -> Bool? = { false },
                            fullAccess: @escaping @Sendable () async -> Bool? = { false },
                            folders: BackendProjectFolders? = nil,
                            every interval: Duration? = .seconds(10)) throws -> BackendCloudLeanRecords? {
        let wantsProjects = enabledRows.contains(projectsRow) && registry != nil, wantsAgents = enabledRows.contains(agentsRow) && roster != nil
        guard wantsProjects || wantsAgents else { return nil }
        let account = try CloudBrainAgentsAccount(subjectHash: subjectHash, deviceID: deviceId)
        let folder = cloudFolder.standardizedFileURL
        let store = try CloudBrainAgentsStore(directory: folder.appendingPathComponent(subjectHash).appendingPathComponent("a2"), account: account,
            clock: .service(serviceTime))
        let origins = try CloudBrainRecordOrigins(cloudFolder: folder, account: subjectHash)
        var adapters: [CloudBrainRecordAdapter] = []
        var projects: BackendCloudLeanProjects?, agents: BackendCloudLeanAgents?
        // Projects first: a project is on this Mac before the agents that name it.
        if wantsProjects, let registry {
            let owner = BackendCloudLeanProjects(registry: registry, display: { await projectsChanged(); await recordsApplied() }, memory: placeMemory, fullAccess: fullAccess, folders: folders,
                                                 deleteStateRoot: folder.appendingPathComponent("records-projects"))
            adapters.append(try owner.adapter(store: store, account: account, origins: origins)); projects = owner
        }
        if wantsAgents, let roster {
            // This Mac's project ids, from the same registry (whether or not the projects row is on).
            let projectIDs: @Sendable () async -> [String]? = {
                guard let registry, let all = try? await registry.projects() else { return nil }
                return all.map { $0.id }
            }
            let owner = BackendCloudLeanAgents(config: roster, historyFile: folder.appendingPathComponent("a2-agent-names.json"),
                defaultProvider: defaultProvider, firstArrivalConfirmed: firstArrivalConfirmed, fullAccess: fullAccess, projects: projectIDs, display: { await agentsChanged(); await recordsApplied() })
            adapters.append(try owner.adapter(store: store, account: account, origins: origins)); agents = owner
        }
        return .init(projects: projects, agents: agents, adapters: adapters,
            activation: try CloudBrainRecordActivation(adapters: adapters, store: store, every: interval),
            tools: BackendCloudLeanTools(adapters: adapters), store: store)
    }
}
