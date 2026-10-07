import Foundation
import AppKit
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    /// Everything the machine area needs except its registration: the deck-tools catalogue
    /// (built after Hoot) must own the six machines.* ids first; `registerMachines` then
    /// installs the area in shared mode over those same definitions.
    func prepareMachines(endpoint: BackendRemoteHost, trust: BackendRemoteTrustStore) async throws {
        let store = BackendMachineStore(directory: root.dataRoot.appendingPathComponent("remote"))
        machineStore = store
        let watch = BackendDeckToolsMachinesWatch()
        try await watch.start(registry: root.registry)
        // TS index.ts machinesIpc window deps: held rows (browser-binding heldRowsFor), the windows a
        // peer's sessions hold there (machineWindowAsks.held) and its answers (machineWindowAsks.answer).
        let machineAsks = BackendRemoteServeWindowAsks()
        machineWindowAsks = machineAsks
        let browser = try NativeCompositionRoot.shared.browserForComposition()
        let hostName = Host.current().localizedName ?? "Mac"
        let browserServices = BackendMachineWindowServices(allowedTools: ["browser.windows", "browser.read", "browser.click", "browser.type", "browser.scroll", "browser.key"],
            call: { [joins] tool, args, caller in try await joins.machineWindowCall(tool, arguments: args, caller: caller) },
            attended: { await MainActor.run { NSApp.isActive } },
            held: { peer in await MainActor.run { Self.heldRows(browser.bindings, peer: peer, selfName: hostName) } },
            ownSessions: { [sessions] in sessions!.manager.list().map(BackendCompositionSuppliers.sessionWire) },
            receivedHolds: { peer, held, _ in await machineAsks.held(deviceID: peer, sessions: held) },
            receivedResult: { id, ok, body in await machineAsks.answer(id: id, result: .init(ok: ok, body: body)) })
        let coordinator = BackendMachineCoordinator(store: store, registry: root.registry,
            localName: Host.current().localizedName ?? "Mac", relayURL: BackendRelayAddress.resolve() ?? "",
            uploadAuthorize: { [files] url, context in try await files!.authority.authorize(url.path, context: context) },
            ownPorts: root.ownPorts, windows: browserServices,
            pairingBlocked: { [state] in state.settingsEnvelope()["values"]["remote.enabled"].bool == false ? "Remote access is disabled." : nil },
            // TS browser-reach.ts: a dropped link forgets every reach it held.
            tunnelsDropped: { [weak self] id in await (await MainActor.run { self?.reachLedger })?.forget(id) })
        machineCoordinator = coordinator; joins.bindMachines(coordinator)
        let panels = BackendRemotePanelRegistry()
        guard let index = files.artifacts, let previews = files.previews, let mcp = clients.mcpClients else {
            throw NativeRPCError(code: "composition-incomplete", message: "Machine panels need the actual artifacts, preview and MCP owners.")
        }
        try await panels.register(.artifacts, provider: BackendRemotePanelArtifacts.provider(index: index, previews: previews))
        try await panels.register(.readiness, provider: BackendRemotePanelReadiness.provider(service: usage.readiness))
        try await panels.register(.mcp, provider: BackendRemotePanelMCP.provider(.init(list: { folder, _ in
            let values = try await mcp.list(.string(folder)).requireArray("MCP rows")
            return values.compactMap { value in
                guard let id = value["id"].string, let name = value["name"].string else { return nil }
                return .init(id: id, name: name, scope: value["scope"].string ?? "user", transport: value["transport"].string ?? "stdio",
                    commandLine: value["command"].string ?? "", url: value["url"].string ?? "", envKeys: value["envKeys"].elements?.compactMap(\.string) ?? [],
                    enabled: value["enabled"].bool != false, disabledReason: value["disabledReason"].string, unsupported: value["unsupported"].string)
            }
        }, add: { request, _ in await mcp.writer.add(request) }, edit: { server, next, _ in
            await mcp.writer.edit(next.setting("id", .string(server.id)).setting("name", .string(server.name)).setting("scope", .string(server.scope)))
        }, remove: { server, folder, _ in await mcp.writer.remove(.object([.init("name", .string(server.name)), .init("scope", .string(server.scope)), .init("projectPath", .string(folder))])) },
            connect: { server, _ in try await mcp.inventory(.string(server.id), project: .missing) }, disconnect: { id, _ in _ = try await mcp.disconnect(.string(id)) })))
        try await panels.register(.store, provider: BackendRemotePanelStore.provider(servers: .init(read: { project, _ in await mcp.store.view(project: project) },
            install: { request, _ in await mcp.store.install(request) }), categoryNames: [:]))
        let uploads = BackendUploadReceive(destination: { [files, configuration] context, proposed in
            let folder = proposed ?? configuration.homeDirectory.appendingPathComponent("Downloads").path
            return try await files!.authority.authorize(folder, context: context.rpcContext, intent: .write)
        })
        let tunnels = BackendRemoteGuestTunnelHost(ownPorts: root.ownPorts, scan: { [files] in try await files!.ports.scan(force: true) },
            // TS server.ts hubFor: the desktop supplies no copilotEligible rule, so an approved
            // device is offered every scanned port; the hub itself drops reserved/own ports.
            authorize: { [trust] _, context in await trust.isApproved(context.deviceID) }, push: { connection, message in try await endpoint.sendToConnection(connection, message: message) })
        let contribution = try await BackendMachineMCP.contribution(registry: root.registry, watch: .init(
            screen: { await watch.screen($0, $1) }, attached: { await watch.attached($0, $1) },
            conversation: { await watch.conversation($0) }, changed: { machine, ceiling in try await watch.nextChange(machine, ceilingMS: ceiling, after: {}) },
            replied: { await watch.replied($0, since: $1, ceilingMS: $2) }), access: .init(
                rpcContext: { [authority] in try await authority!.rpc($0) },
                authorize: { [joins] native, tool, _, tier in try await joins.prepareNative(native, tier: tier, sentence: "Use " + tool) },
                startedByYou: { [authority] native, key in (try? await authority!.resolve(native).startedByCopilot(key)) == true },
                noteStarted: { [authority] native, key in if let context = try? await authority!.resolve(native) { context.noteStarted(key) } },
                requireLocalMachineAuthority: { [authority] native, _ in guard try await authority!.resolve(native).caller.actsAsOwner else { throw NativeRPCError(code: "access-denied", message: "This operation belongs to the desktop's machine owner.") } }))
        let catalogue = try BackendDeckToolsMachinesCatalogue.rows()
        machineDefinitions = contribution.map { spec, handler -> BackendDeckToolsDefinition in
            let row = catalogue.first { $0["id"].string == spec.id }
            return .init(spec: spec, title: row?["title"].string ?? spec.id, index: row?["index"].string, handler: handler)
        }
        machinePending = .init(coordinator: coordinator, browser: browserServices, panels: panels, uploads: uploads,
            tunnels: tunnels, endpoint: endpoint, watch: watch)
    }

    /// TS browser-binding.ts heldRowsFor: this Mac's windows bound to sessions on `peer`.
    static func heldRows(_ bindings: BackendBrowserBindings, peer: String, selfName: String) -> [NativeRPCValue] {
        guard !peer.isEmpty else { return [] }
        let grouped = bindings.bindings(for: .init(ownerID: BackendCompositionRoot.appOwnerID, managesWindows: true)).windows
        var rows: [NativeRPCValue] = []
        for (key, windows) in grouped.sorted(by: { $0.key < $1.key }) where !windows.isEmpty {
            let parts = key.split(separator: "\u{0}", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, parts[1] == peer else { continue }
            let label: (String) -> String = { BackendSharedHeldWindows.heldLabel(.string($0)) }
            rows.append(.object([.init("session", .string(parts[0])), .init("windows", .array(windows.sorted { $0.n < $1.n }.map { bound in
                let window = bindings.window(bound.tabID)
                let host = window.map { $0.hostMachineID.isEmpty ? selfName : $0.hostMachineID == peer ? "" : ($0.hostMachineName.isEmpty ? $0.hostMachineID : $0.hostMachineName) } ?? selfName
                return .object([.init("n", .number(Double(bound.n))), .init("title", .string(label(window?.title ?? ""))),
                    .init("url", .string(label(window?.url ?? ""))), .init("host", .string(label(host)))])
            }))]))
        }
        return rows
    }

    /// TS machine channels: reads need a current core-call ticket, changes an accepted mutation.
    nonisolated static func machineChannelIsRead(_ channel: String) -> Bool {
        channel.hasSuffix(":read") || ["machines:list", "machines:ports", "machines:attach", "machines:detach", "machines:reach"].contains(channel)
    }

    func registerMachines() async throws {
        guard let pending = machinePending, let remoteHost else {
            throw NativeRPCError(code: "composition-incomplete", message: "Machines need their prepared owners and the remote host.")
        }
        let coordinator = pending.coordinator, endpoint = pending.endpoint, watch = pending.watch
        let definitions = machineDefinitions
        let policies = definitions.map { joins.nativePolicy($0) }
        let server = root.mcp
        machineOwner = try await root.installMachines(dependencies: .init(coordinator: coordinator, localHost: remoteHost, browser: pending.browser,
            panels: pending.panels, uploads: pending.uploads, tunnels: pending.tunnels,
            host: .init(endpoint: endpoint, install: { owner, features, closed in
                try await endpoint.installFeatures(ownerID: owner, features: features, connectionClosed: closed)
            }, currentContext: { try await endpoint.refreshedContext($0) }, authorize: { [files] message, context in
                let current = try await endpoint.refreshedContext(context)
                if let path = message["path"].string { _ = try await files!.authority.authorize(path, context: current.rpcContext,
                    intent: message.type == "panel.act" || message.type.hasPrefix("upload.") ? .write : .read) }
                return current.rpcContext
            }, connectionRows: { .array(await endpoint.remoteServeConnectionRows()) }),
            mcp: .init(mode: .shared(ownerID: BackendDeckToolsRegistration.ownerID), definitions: definitions, policies: policies,
                authenticate: { [authority] native, _, _ in try await authority!.rpc(native) },
                requireSharedOwner: { owner, ids in
                    for id in ids where await server.ownerOf(id) != owner {
                        throw NativeRPCError(code: "composition-conflict", message: "The machine tool \(id) is not owned by the deck-tools contribution.")
                    }
                },
                disconnect: { [usage] context in await usage!.disconnect(ownerID: context.ownerID) }),
            transferredDomains: ["machines", "remote-serve"], requireSuppliers: { [joins] in _ = try joins.sessions(); _ = try joins.authority() },
            authorizeInvoke: { [authority] channel, context, _ in
                if Self.machineChannelIsRead(channel) { try authority!.authorizeMetadata(context) } else { try authority!.authorizeMutation(context) }
            },
            activate: { _ in try await coordinator.open(connectSaved: true); return [] },
            deactivate: { await coordinator.stop(); await watch.dispose() }))
    }
}

struct NativeCompositionMachinesPending {
    let coordinator: BackendMachineCoordinator
    let browser: BackendMachineWindowServices
    let panels: BackendRemotePanelRegistry
    let uploads: BackendUploadReceive
    let tunnels: BackendRemoteGuestTunnelHost
    let endpoint: BackendRemoteHost
    let watch: BackendDeckToolsMachinesWatch
}
