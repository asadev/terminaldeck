import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    func allowsINT2PhoneTasks(_ caller: BackendDeckCoreSecurityCaller, mutation: Bool, project: String? = nil) async -> Bool {
        guard caller.kind == .remote, let device = caller.deviceID,
              let source = BackendINT2PhonePanelCaller.current, source.deviceID == device,
              let trust = remoteTrust, let endpoint = remoteEndpoint,
              let current = try? await endpoint.refreshedContext(source), current.deviceID == device,
              let level = await trust.phoneAccess(device), !mutation || level != .look else { return false }
        guard let project else { return true }
        return current.reach.folders.contains { BackendRemoteTrustStore.within($0, project) }
    }

    func installINT2PhoneAccess(access: BackendDeckToolsAppAccess) async throws {
        guard let trust = remoteTrust, let endpoint = remoteEndpoint else {
            throw NativeRPCError(code: "composition-incomplete", message: "Phone access needs the actual paired-device owner.")
        }
        let owner = "native.phone-access", authority = self.authority!, root = self.root, joins = self.joins
        let list = "remote:device-access", set = "remote:device-access:set"
        try await root.registry.register(list, ownerID: owner, policy: { try authority.requireLocalUI($0) }) { _, args in
            guard args.isEmpty else { throw NativeRPCError.invalidArguments("Phone access takes no list arguments.") }
            return await trust.phoneAccessRows()
        }
        try await root.registry.register(set, ownerID: owner, policy: { try authority.requireLocalUI($0) }) { rpc, args in
            try rpc.requireCount(args, 2...2)
            let id = try args[0].requireString("device", nonempty: true)
            guard let level = args[1].string.flatMap(BackendINT2PhoneAccessLevel.init(rawValue:)) else {
                throw NativeRPCError.invalidArguments("Choose Look only, Work or Full control.")
            }
            try authority.requireLocalUI(rpc); try await trust.setPhoneAccess(id, level: level)
            await endpoint.phoneAccessChanged(id)
            return await trust.phoneAccessRows()
        }
        let definitions = try BackendINT2PhoneAccessMCP.definitions(trust: trust, access: access, changed: { id in
            await endpoint.phoneAccessChanged(id)
        })
        let policies = definitions.map { joins.nativePolicy($0) }
        let bundle = try BackendDeckCoreCatalogueBundle(metadata: definitions.map(\.catalogueMetadata), policies: policies)
        do {
            try joins.replaceContributions(owner: owner, [bundle], policiesWrapped: true)
            try await root.mcp.replaceTools(ownerID: owner, tools: definitions.map { ($0.spec, $0.handler) })
            try await root.retain(.init(name: "phone-access", domains: ["phone-access"], ownerID: owner,
                invokes: [list, set], stop: {
                    await root.registry.removeOwner(owner); await root.mcp.removeTools(ownerID: owner)
                    try joins.replaceContributions(owner: owner, [], policiesWrapped: true)
                }))
        } catch {
            await root.registry.removeOwner(owner); await root.mcp.removeTools(ownerID: owner)
            try? joins.replaceContributions(owner: owner, [], policiesWrapped: true); throw error
        }
    }
}
