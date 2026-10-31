import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// The phone's Activity page (31 Oct): the remote `activity` capability and the `system.activity` tool, both read by
/// one `BackendSystemActivity`, which names a session's processes "<project> · <title>" from this Mac's own list.
/// Not fatal: without it the phone shows no Activity page and the tool is absent.
extension NativeCompositionProduction {
    /// The reader, made once and shared by the stream and the tool.
    func systemActivityReader() -> BackendSystemActivity {
        if let reader = systemActivity { return reader }
        let manager = sessions?.manager
        let reader = BackendSystemActivity(home: configuration.homeDirectory.path, sessions: {
            guard let manager else { return [] }
            return manager.list().compactMap { meta in
                guard meta.exitCode == nil, let pid = manager.pidOf(meta.id), pid > 1 else { return nil }
                return .init(pid: pid, label: NativePhoneActivityNames.label(folder: meta.cwd, title: meta.title))
            }
        })
        systemActivity = reader
        return reader
    }

    func installPhoneActivity() async {
        guard let endpoint = remoteEndpoint else {
            report("Phone activity is unavailable: the remote endpoint is not wired.")
            return
        }
        let stream = BackendPhoneActivity(endpoint: endpoint, reader: systemActivityReader())
        let owner = "native.phone-activity"
        do {
            let lease = try await endpoint.installFeatures(ownerID: owner, features: [await stream.feature()],
                connectionClosed: { await stream.disconnected($0) })
            do {
                try await root.retain(.init(name: "phone-activity", domains: ["phone-activity"], ownerID: owner, invokes: [], stop: {
                    await stream.stop(); await lease.cancelAndWait()
                }))
                phoneActivity = stream
            } catch { await stream.stop(); await lease.cancelAndWait(); throw error }
        } catch {
            report("Phone activity is unavailable: " + error.localizedDescription)
        }
    }

    func installSystemActivityTool(access: BackendDeckToolsAppAccess) async throws {
        let owner = "native.system-activity-tool", root = self.root, joins = self.joins
        let definitions = try BackendSystemActivityMCP.definitions(reader: systemActivityReader(), access: access)
        let bundle = try BackendDeckCoreCatalogueBundle(metadata: definitions.map(\.catalogueMetadata), policies: definitions.map { joins.nativePolicy($0) })
        do {
            try joins.replaceContributions(owner: owner, [bundle], policiesWrapped: true)
            try await root.mcp.replaceTools(ownerID: owner, tools: definitions.map { ($0.spec, $0.handler) })
            try await root.retain(.init(name: "system-activity-tool", domains: ["system-activity-tool"], ownerID: owner, invokes: [], stop: {
                await root.mcp.removeTools(ownerID: owner); try joins.replaceContributions(owner: owner, [], policiesWrapped: true)
            }))
        } catch {
            await root.mcp.removeTools(ownerID: owner); try? joins.replaceContributions(owner: owner, [], policiesWrapped: true); throw error
        }
    }
}

enum NativePhoneActivityNames {
    /// "Deck Dev · build": the project folder's name, then the session's own title when it says something more.
    static func label(folder: String, title: String) -> String {
        let project = URL(fileURLWithPath: folder).lastPathComponent
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == project { return project.isEmpty ? "Session" : project }
        return project.isEmpty ? name : "\(project) · \(name)"
    }
}
