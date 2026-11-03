import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    func installTasksPageTools(store: BackendTaskStore, local: BackendTaskLocalService,
                               taskAuthority: BackendTaskToolAuthority) async throws {
        let owner = "native-composition:tasks-page", mcp = root.mcp, joins = self.joins
        do {
            try await BackendTasksPageTools.install(server: mcp, ownerID: owner, authority: taskAuthority,
                store: store, local: local, views: { args in try await MainActor.run { try MyWorkModel.shared.viewsTool(args) } })
            let registrations = await mcp.registrations().filter { BackendTasksPageTools.ids.contains($0.0.id) }
            let metadata = registrations.map { BackendDeckCoreCatalogueMetadata(tool: $0.0, title: $0.0.description, index: $0.0.description) }
            let policies = zip(metadata, registrations).map { joins.mcpPolicy($0.0, handler: $0.1.1) }
            try joins.replaceContributions(owner: owner, [try .init(metadata: metadata, policies: policies)], policiesWrapped: true)
            try await root.retain(.init(name: "tasks-page", domains: ["tasks-page"], ownerID: owner, invokes: [], sends: [], events: [], stop: {
                try? joins.replaceContributions(owner: owner, [], policiesWrapped: true)
                await mcp.removeTools(ownerID: owner)
            }))
        } catch {
            try? joins.replaceContributions(owner: owner, [], policiesWrapped: true)
            await mcp.removeTools(ownerID: owner)
            throw error
        }
    }
}

extension MyWorkModel {
    func viewsTool(_ args: NativeRPCValue) throws -> NativeRPCValue {
        let verb = args["do"].string ?? "list"
        if ["select", "rename", "delete", "resave", "revert"].contains(verb) {
            guard let id = args["id"].string, savedViews.contains(where: { $0.id == id }) else {
                throw NativeRPCError.invalidArguments("Choose an existing saved view id.")
            }
        }
        if ["save", "rename"].contains(verb) {
            guard let name = args["name"].string, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NativeRPCError.invalidArguments("Give this view a name.")
            }
        }
        switch verb {
        case "list": break
        case "save": saveView(named: args["name"].string ?? "")
        case "select": selectView(args["id"].string ?? "")
        case "rename": renameView(args["id"].string ?? "", to: args["name"].string ?? "")
        case "delete": deleteView(args["id"].string ?? "")
        case "resave", "revert":
            guard args["id"].string == activeViewID else { throw NativeRPCError.invalidArguments("Select that saved view first; only the open one can be updated or reverted.") }
            if verb == "resave" { resaveView(args["id"].string ?? "") } else { revertView(args["id"].string ?? "") }
        case "update":
            _ = try args["state"].requireObject("state")
            view = TasksViewState.read(args["state"].foundation)
        default: throw NativeRPCError.invalidArguments("Unknown saved view action.")
        }
        return try .fromFoundation(["current": view.json, "active": (activeViewID as Any?) ?? NSNull(), "changed": activeViewChanged, "views": savedViews.map(\.json)])
    }
}
